defmodule MAVLink.Router do
  @moduledoc """
  Connect to serial, udp and tcp ports and listen for, validate and
  forward MAVLink messages towards their destinations on other connections
  and/or Elixir processes subscribing to messages.
  
  The rules for MAVLink packet forwarding are described here:
  
    https://mavlink.io/en/guide/routing.html
  
  and here:
  
    http://ardupilot.org/dev/docs/mavlink-routing-in-ardupilot.html
  """
  
  use GenServer
  require Logger
  
  import MAVLink.Utils, only: [parse_ip_address: 1, parse_positive_integer: 1]
  import Enum, only: [reduce: 3, filter: 2, map: 2]
  
  alias MAVLink.Frame
  alias MAVLink.Message
  alias MAVLink.Router
  alias MAVLink.SerialConnection
  alias MAVLink.TCPOutConnection
  alias MAVLink.Types
  alias MAVLink.UDPInConnection
  alias MAVLink.UDPOutConnection
  alias Circuits.UART
  
  
  # Router State
  # ------------
  # connections are configured by the user when the server starts. Broadcast messages
  # (e.g. heartbeat) are always sent to all connections, whereas targeted messages
  # are only sent to systems we have already seen and recorded in the routes map.
  # subscriptions are where we record the queries and pids of local Elixir processes
  # to forward messages to.

  defstruct [
    dialect: nil,                             # Generated dialect module
    system: 240,                               # Default to ground station
    component: 1,
    connection_strings: [],                   # Connection descriptions from user
    connections: %{},                         # %{socket|port: MAVLink.*_Connection}
    routes: %{},                              # Connection and MAVLink version tuple keyed by MAVLink addresses
    subscriptions: [],                        # Local Connection Elixir process queries
    sequence_number: 0,                       # Sequence number of next sent message
  ]
  @type mavlink_address :: Types.mavlink_address  # Can't used qualified type as map key
  @type mavlink_connection :: Types.connection
  @type t :: %Router{
               dialect: module | nil,
               system: non_neg_integer,
               component: non_neg_integer,
               connection_strings: [ String.t ],
               connections: %{},
               routes: %{mavlink_address: {mavlink_connection, Types.version}},
               subscriptions: [],
               sequence_number: Types.sequence_number,
             }
  
             
             
             
  ##############
  # Router API #
  ##############
  
  @spec start_link(%{dialect: module, system: non_neg_integer, component: non_neg_integer,
    connection_strings: [String.t]}, [{atom, any}]) :: {:ok, pid}
  def start_link(state, opts \\ []) do
    GenServer.start_link(
      __MODULE__,
      state,
      [{:name, __MODULE__} | opts])
  end
  
  
  @doc """
  Subscribes the calling process to messages matching the query.
  Zero or more of the following query keywords are supported:
  
    message:          message_module
    source_system:    integer 0..255
    source_component: integer 0..255
    target_system:    integer 0..255
    target_component: integer 0..255
    as_frame:         true|false (default false)
    
  For example:
  
  ```
    MAVLink.Router.subscribe message: MAVLink.Message.Heartbeat, source_system: 1
  ```
  """
  @type subscribe_query_id_key :: :source_system | :source_component | :target_system | :target_component
  @spec subscribe([{:message, Message.t} | {subscribe_query_id_key, 0..255}]) :: :ok
  def subscribe(query \\ []) do
    with message <- Keyword.get(query, :message),
        true <- message == nil or Code.ensure_loaded?(message) do
      GenServer.cast(
        __MODULE__,
        {
          :subscribe,
          [
            message: nil,
            source_system: 0,
            source_component: 0,
            target_system: 0,
            target_component: 0,
            as_frame: false
          ]
          |> Keyword.merge(query)
          |> Enum.into(%{}),
          self()
        }
      )
    else
      false ->
        {:error, :invalid_message}
    end
  end
  
  
  @doc """
  Un-subscribes calling process from all existing subscriptions
  """
  @spec unsubscribe() :: :ok
  def unsubscribe(), do: GenServer.cast(__MODULE__, {:unsubscribe, self()})
  
  
  
  @doc """
  Send a MAVLink message to one or more recipients using available
  connections. For now if destination is unreachable it will fail
  silently.
  """
  def pack_and_send(message, version \\ 2) do
    # We can only pack payload at this point because we nee router state to get source
    # system/component and sequence number for frame
    try do
      {:ok, message_id, {:ok, crc_extra, _, targeted?}, payload} = Message.pack(message, version)
      {target_system, target_component} = if targeted? do
        {message.target_system, message.target_component}
      else
        {0, 0}
      end
      GenServer.cast(
        __MODULE__,
        {
          :send,
          struct(Frame, [
            version: version,
            message_id: message_id,
            target_system: target_system,
            target_component: target_component,
            targeted?: targeted?,
            message: message,
            payload: payload,
            crc_extra: crc_extra])
        }
      )
      :ok
    rescue
      # Need to catch Protocol.UndefinedError - happens with SimState (Common) and Simstate (APM)
      # messages because non-case-sensitive filesystems (including OSX thanks @noobz) can't tell
      # the difference between generated module beam files. Work around is comment out one of the
      # message definitions and regenerate.
      Protocol.UndefinedError ->
        {:error, :protocol_undefined}
    end
  end
  
  
  
  
  #######################
  # GenServer Callbacks #
  #######################
  
  @impl true
  def init(%Router{dialect: nil}) do
    {:error, :no_mavlink_dialect_set}
  end
  
  def init(state = %Router{connection_strings: connection_strings}) do
    map(connection_strings, &connect/1)
    case Agent.start(fn -> [] end, name: MAVLink.SubscriptionCache) do
      {:ok, _} ->
        Logger.info("Started Subscription Cache")
        {:ok, state}
      {:error, {:already_started, _}} ->
        Logger.info("Restoring subscriptions from Subscription Cache")
        {
          :ok,
          reduce(
            Agent.get(MAVLink.SubscriptionCache, fn subs -> subs end),
            state,
            fn {query, pid}, state -> subscribe(query, pid, state)  end)
        }
    end
  end
  
  
  @impl true
  def handle_cast({:subscribe, query, pid}, state) do
    {:noreply, subscribe(query, pid, state)}
  end
  
  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, unsubscribe(pid, state)}
  end
  
  def handle_cast(
        {:send, frame},
        state=%Router{
          sequence_number: sequence_number,
          system: system,
          component: component}) do
    {
      :noreply,
      route({
        :ok,
        :local,
        Frame.pack_frame(
          struct(frame, [
            sequence_number: sequence_number,
            source_system: system,
            source_component: component
          ])
        ),
        struct(state, [
          sequence_number: rem(sequence_number + 1, 255)
        ])}
      )
    }
  end
  

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, state), do: {:noreply, subscriber_down(pid, state)}
  
  # Process incoming messages from connection ports
  def handle_info(message = {:udp, socket, address, port, _},
        state = %Router{connections: connections, dialect: dialect}) do
    {
       :noreply,
       case connections[{socket, address, port}] do
         connection = %UDPInConnection{} ->
           UDPInConnection.handle_info(message, connection, dialect)
         connection = %UDPOutConnection{} ->
           UDPOutConnection.handle_info(message, connection, dialect)
         nil ->
           # New unseen UDPIn client
           UDPInConnection.handle_info(message, nil, dialect)
       end
       |> update_route_info(state)
       |> route
    }
  end
  
  def handle_info(message = {:tcp, socket, _}, state) do
    {
      :noreply,
      TCPOutConnection.handle_info(message, state.connections[socket], state.dialect)
      |> update_route_info(state)
      |> route
    }
  end
  
  def handle_info({:tcp_closed, socket}, state) do
    %TCPOutConnection{address: address, port: port} = state.connections[socket]
    spawn TCPOutConnection, :connect, [["tcpout", address, port], self()]
    {:noreply, remove_connection(socket, state)}
  end
  
  # No equivalent close to handle for UDP
  
  def handle_info(message = {:circuits_uart, port, raw}, state) when is_binary(raw) do
    {
      :noreply,
      SerialConnection.handle_info(message, state.connections[port], state.dialect)
      |> update_route_info(state)
      |> route
    }
  end
  
  def handle_info({:circuits_uart, port, {:error, _reason}}, state) do
    %SerialConnection{baud: baud, uart: uart} = state.connections[port]
    spawn SerialConnection, :connect, [["serial", port, baud, :poolboy.checkout(MAVLink.UARTPool)], self()]
    UART.close(uart)
    :poolboy.checkin(MAVLink.UARTPool, uart) # After checkout to make sure we get a fresh one, this one might be reused later
    {:noreply, remove_connection(port, state)}
  end

  def handle_info({:add_connection, connection_key, connection},
        state=%Router{connections: connections}) do
    {
      :noreply,
      struct(
        state,
        [connections: Map.put(connections, connection_key, connection)]
      )
    }
  end
  
  def handle_info(_msg, state) do
    {:noreply, state}
  end
  
  
  
  
  ####################
  # Helper Functions #
  ####################
  
  
  defp connect(connection_string) when is_binary(connection_string), do: connect String.split(connection_string, [":", ","])
  defp connect(tokens = ["udpin" | _]), do: spawn UDPInConnection, :connect, [validate_address_and_port(tokens), self()]
  defp connect(tokens = ["udpout" | _]), do: spawn UDPOutConnection, :connect, [validate_address_and_port(tokens), self()]
  defp connect(tokens = ["tcpout" | _]), do: spawn TCPOutConnection, :connect, [validate_address_and_port(tokens), self()]
  defp connect(tokens = ["serial" | _]), do: spawn SerialConnection, :connect, [validate_port_and_baud(tokens), self()]
  defp connect([invalid_protocol | _]), do: raise(ArgumentError, message: "invalid protocol #{invalid_protocol}")
  
  
  defp remove_connection(connection_key, state=%Router{connections: connections}) do
    struct(state, [connections: Map.delete(connections, connection_key)])
  end
  
  
  # Map system/component ids to connections on which they have been seen for targeted messages
  # Keep a list of all connections we have received messages from for broadcast messages
  defp update_route_info({:ok,
        source_connection_key,
        source_connection,
        frame=%Frame{
          source_system: source_system,
          source_component: source_component
        }
      },
      state=%Router{routes: routes, connections: connections}) do
    {
      :ok,
      source_connection_key,
      frame,
      struct(
        state,
        [
          routes: Map.put(
            routes,
            {source_system, source_component},
            source_connection_key),
          connections: Map.put(
            connections,
            source_connection_key,
            source_connection)
        ]
      )
    }
    
  end
  
  # Connections buffers etc still need to be updated if there is an error
  defp update_route_info(
         {:error, reason, connection_key, connection},
         state=%Router{connections: connections}) do
    {
      :error,
      reason,
      struct(
        state,
        [
          connections: Map.put(
            connections,
            connection_key,
            connection
          )
        ]
      )
    }
  end
  
  # Broadcast un-targeted messages to all connections except the
  # source we received the message from
  defp route({:ok,
        source_connection_key,
        frame=%Frame{target: :broadcast},
        state=%Router{connections: connections, subscriptions: subscriptions}}) do
    for {connection_key, connection} <- connections do
      unless match?(^connection_key, source_connection_key) do
        forward(connection, frame)
      end
    end
    forward(:local, frame, subscriptions)
    state
  end
  
  # Only send targeted messages to observed system/components
  defp route({:ok,
        _,
        frame=%Frame{target_system: target_system, target_component: target_component},
        state=%Router{connections: connections}}) do
    for connection_key <- matching_system_components(target_system, target_component, state) do
      forward(connections[connection_key], frame)
    end
    forward(:local, frame, state.subscriptions)
    state
  end
  
  defp route({:error, _reason, state=%Router{}}), do: state
  
  
  # Delegate sending a message to non-local connection-type specific code
  defp forward(connection=%UDPInConnection{}, frame), do: UDPInConnection.forward(connection, frame)
  defp forward(connection=%UDPOutConnection{}, frame), do: UDPOutConnection.forward(connection, frame)
  defp forward(connection=%TCPOutConnection{}, frame), do: TCPOutConnection.forward(connection, frame)
  defp forward(connection=%SerialConnection{}, frame), do: SerialConnection.forward(connection, frame)
 
  #  Forward a message to a local subscribed Elixir process.
  #  TODO after all the changes perhaps we could try factoring out LocalConnection again...
  defp forward(:local, frame = %Frame{message: nil}, subscriptions) do
    forward(:local, struct(frame, message: %{__struct__: :unknown}), subscriptions)
  end
  defp forward(:local, frame = %Frame{
        source_system: source_system,
        source_component: source_component,
        target_system: target_system,
        target_component: target_component,
        target: target,
        message: message = %{__struct__: message_type}
      }, subscriptions) do
    for {
          %{
            message: q_message_type,
            source_system: q_source_system,
            source_component: q_source_component,
            target_system: q_target_system,
            target_component: q_target_component,
            as_frame: as_frame?
          },
          pid} <- subscriptions do
      if (q_message_type == nil or q_message_type == message_type)
          and (q_source_system == 0 or q_source_system == source_system)
          and (q_source_component == 0 or q_source_component == source_component)
          and (q_target_system == 0 or (target != :broadcast and target != :component and q_target_system == target_system))
          and (q_target_component == 0 or (target != :broadcast and target != :system and q_target_component == target_component)) do
        send(pid, (if as_frame?, do: frame, else: message))
      end
    end
  end

  
  defp validate_address_and_port([protocol, address, port]) do
    case {parse_ip_address(address), parse_positive_integer(port)} do
      {{:error, :invalid_ip_address}, _}->
        raise ArgumentError, message: "invalid ip address #{address}"
      {_, :error} ->
        raise ArgumentError, message: "invalid port #{port}"
      {parsed_address, parsed_port} ->
        [protocol, parsed_address, parsed_port]
    end
  end
  
  
  defp validate_port_and_baud(["serial", port, baud]) do
    case {Map.has_key?(UART.enumerate(), port), parse_positive_integer(baud)} do
      {false, _} ->
        raise ArgumentError, message: "port #{port} not attached"
      {_, :error} ->
        raise ArgumentError, message: "invalid baud rate #{baud}"
      {true, parsed_baud} ->
        # Have to checkout from pool in main process
        ["serial", port, parsed_baud, :poolboy.checkout(MAVLink.UARTPool)]
    end
  end
  
  
  # Subscription request from subscriber
  defp subscribe(query, pid, state) do
    Logger.info("Subscribe #{inspect(pid)} to query #{inspect(query)}")
    # Monitor so that we can unsubscribe dead processes
    Process.monitor(pid)
    # Uniq prevents duplicate subscriptions
    %Router{state | subscriptions: (Enum.uniq([{query, pid} | state.subscriptions]) |> update_subscription_cache)}
  end
  
  
  # Unsubscribe request from subscriber
  defp unsubscribe(pid, state) do
    Logger.info("Unsubscribe #{inspect(pid)}")
    %Router{state | subscriptions: (filter(state.subscriptions, & not match?({_, ^pid}, &1)) |> update_subscription_cache)}
  end
  
  
  # Automatically unsubscribe a dead subscriber process
  defp subscriber_down(pid, state) do
    Logger.info("Subscriber #{inspect(pid)} exited")
    %Router{state | subscriptions: (filter(state.subscriptions, & not match?({_, ^pid}, &1)) |> update_subscription_cache)}
  end
  
  
  defp update_subscription_cache(subscriptions) do
    Logger.info("Update subscription cache: #{inspect(subscriptions)}")
    Agent.update(MAVLink.SubscriptionCache, fn _ -> subscriptions end)
    subscriptions
  end
  
  
  # Known system/components matching target with 0 wildcard
  defp matching_system_components(q_system, q_component,
         %Router{routes: routes}) do
    Enum.filter(
      routes,
      fn {{sid, cid}, _} ->
          (q_system == 0 or q_system == sid) and
          (q_component == 0 or q_component == cid)
      end
    ) |> Enum.map(fn  {_, ck} -> ck end)
  end
  
end
