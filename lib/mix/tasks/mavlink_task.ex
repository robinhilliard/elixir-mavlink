defmodule Mix.Tasks.Mavlink do
  use Mix.Task

  
  import Mavlink.Parser
  import DateTime
  import Enum, only: [count: 1, join: 2, map: 2, filter: 2, reduce: 3, reverse: 1]
  import String, only: [trim: 1, replace: 3, split: 2, capitalize: 1, downcase: 1]
  import Mavlink.Utils
  
  
  @shortdoc "Generate Mavlink Module from XML"
  @spec run([String.t]) :: :ok
  def run(["generate", input, output]) do
    case parse_mavlink_xml(input) do
      {:error, :enoent} ->
        IO.puts("Couldn't open input file '#{input}'.")
        
      %{version: version, dialect: dialect, enums: enums, messages: messages} ->
     
        enum_code_fragments = get_enum_code_fragments(enums)
        message_code_fragments = get_message_code_fragments(messages, enums)
        unit_code_fragments = get_unit_code_fragments(messages)
        
        File.write(output,
        """
        defprotocol Mavlink.Pack do
          def pack(message)
        end
        
        
        defimpl Mavlink.Pack, for: [Atom, BitString, Float, Function, Integer, List, Map, PID, Port, Reference, Tuple] do
          def pack(not_a_message), do: {:error, "pack(): \#{inspect(not_a_message)} is not a Mavlink message"}
        end
        
        
        #{message_code_fragments |> map(& &1.module) |> join("\n\n") |> trim}
        
        
        defmodule Mavlink do
        
          import Enum, only: [reverse: 1]
          
          @moduledoc ~s(Mavlink #{version}.#{dialect} generated by Mavlink mix task from #{input} on #{utc_now()})
          
          @typedoc "A parameter description"
          @type param_description :: {pos_integer, String.t}
          
          
          @typedoc "A list of parameter descriptions"
          @type param_description_list :: [ param_description ]
          
          
          @typedoc "Type used for field in encoded message"
          @type field_type :: int8_t | int16_t | int32_t | int64_t | uint8_t | uint16_t | uint32_t | uint64_t | char | float | double
          
          
          @typedoc "8-bit signed integer"
          @type int8_t :: -128..127
          
          
          @typedoc "16-bit signed integer"
          @type int16_t :: -32_768..32_767
          
          
          @typedoc "32-bit signed integer"
          @type int32_t :: -2_147_483_647..2_147_483_647
          
          
          @typedoc "64-bit signed integer"
          @type int64_t :: integer
          
          
          @typedoc "8-bit unsigned integer"
          @type uint8_t :: 0..255
          
          
          @typedoc "16-bit unsigned integer"
          @type uint16_t :: 0..65_535
          
          
          @typedoc "32-bit unsigned integer"
          @type uint32_t :: 0..4_294_967_295
          
          
          @typedoc "64-bit unsigned integer"
          @type uint64_t :: pos_integer
          
          @typedoc "64-bit signed float"
          @type double :: Float64
          
          
          @typedoc "1 -> not an array 2..255 -> an array"
          @type field_ordinality :: 1..255
          
          
          @typedoc "A Mavlink message id"
          @type message_id :: pos_integer
          
          
          @typedoc "A Mavlink message"
          @type message :: #{map(messages, & "Mavlink.#{&1[:name] |> module_case}") |> join(" | ")}
          
          
          @typedoc "An atom representing a Mavlink enumeration type"
          @type enum_type :: #{map(enums, & ":#{&1[:name]}") |> join(" | ")}
          
          
          @typedoc "An atom representing a Mavlink enumeration type value"
          @type enum_value :: #{map(enums, & "#{&1[:name]}") |> join(" | ")}
          
          
          #{enum_code_fragments |> map(& &1[:type]) |> join("\n\n  ")}
          
          
          @typedoc "Measurement unit of field value"
          @type field_unit :: #{unit_code_fragments |> join(~s( | )) |> trim}
          
          
          @doc "Mavlink version"
          @spec mavlink_version() :: integer
          def mavlink_version(), do: #{version}
          
          
          @doc "Mavlink dialect"
          @spec mavlink_dialect() :: integer
          def mavlink_dialect(), do: #{dialect}
          
          
          @doc "Return a String description of a Mavlink enumeration"
          @spec describe(enum_type | enum_value) :: String.t
          #{enum_code_fragments |> map(& &1[:describe]) |> join("\n  ") |> trim}
          
          
          @doc "Return keyword list of mav_cmd parameters"
          @spec describe_params(mav_cmd) :: param_description_list
          #{enum_code_fragments |> map(& &1[:describe_params]) |> join("\n  ") |> trim}
          
          
          @doc "Return encoded integer value used in a Mavlink message for an enumeration value"
          @spec encode(enum_value) :: integer
          #{enum_code_fragments |> map(& &1[:encode]) |> join("\n  ") |> trim}
          
          
          @doc "Return the atom representation of a Mavlink enumeration value from the enumeration type and encoded integer"
          @spec decode(enum_type, integer) :: enum_value
          #{enum_code_fragments |> map(& &1[:decode]) |> join("\n  ") |> trim}
          def decode(_, value), do: value
          
          
          @doc "Return the message checksum for a message with a specified id"
          @spec msg_crc_size(message_id) :: {0..255, pos_integer}
          #{message_code_fragments |> map(& &1.msg_crc_size) |> join("") |> trim}
          def msg_crc_size(_), do: {:error, :unknown_message_id}
          
          @doc "helper function to unpack array fields"
          def unpack_array(bin, fun), do: unpack_array(bin, fun, [])
          def unpack_array(<<>>, _, lst), do: reverse(lst)
          def unpack_array(bin, fun, lst) do
            {elem, rest} = fun.(bin)
            unpack_array(rest, fun, [elem | lst])
          end
        
          @doc "Unpack a Mavlink message given a Mavlink frame's message id and payload"
          @spec unpack(message_id, binary) :: message
          #{message_code_fragments |> map(& &1.unpack) |> join("") |> trim}
          def unpack(_, _), do: {:error, :unknown_message}
          
        end
        """
        )
      
        IO.puts("Generated output file '#{output}'.")
        :ok
    
    end
    
  end
  
  
  @type enum_detail :: %{type: String.t, describe: String.t, describe_params: String.t, encode: String.t, decode: String.t}
  @spec get_enum_code_fragments([Mavlink.Parser.enum_description]) :: [ enum_detail ]
  defp get_enum_code_fragments(enums) do
    for enum <- enums do
      %{
        name: name,
        description: description,
        entries: entries
      } = enum
      
      entry_code_fragments = get_entry_code_fragments(name, entries)
      
      %{
        type: ~s/@typedoc "#{description}"\n  / <>
          ~s/@type #{name} :: / <>
          (map(entry_code_fragments, & ":#{&1[:name]}") |> join(" | ")),
          
        describe: ~s/def describe(:#{name}), do: "#{escape(description)}"\n  / <>
          (map(entry_code_fragments, & &1[:describe])
          |> join("\n  ")),
          
        describe_params: filter(entry_code_fragments, & &1 != nil)
          |> map(& &1[:describe_params])
          |> join("\n  "),
          
        encode: map(entry_code_fragments, & &1[:encode])
          |> join("\n  "),
        
        decode: map(entry_code_fragments, & &1[:decode])
          |> join("\n  ")
      }
    end
  end
  
  
  @type entry_detail :: %{name: String.t, describe: String.t, describe_params: String.t, encode: String.t, decode: String.t}
  @spec get_entry_code_fragments(String.t, [Mavlink.Parser.entry_description]) :: [ entry_detail ]
  defp get_entry_code_fragments(enum_name, entries) do
    {details, _} = reduce(
      entries,
      {[], 0},
      fn entry, {details, next_value} ->
        %{
          name: entry_name,
          description: entry_description,
          value: entry_value,
          params: entry_params
        } = entry
        
        # Use provided value or continue monotonically from last value: in common.xml MAV_STATE uses this
        {entry_value_string, next_value} = case entry_value do
          nil ->
            {Integer.to_string(next_value), next_value + 1}
          _ ->
            {Integer.to_string(entry_value), entry_value + 1}
        end
        
        {
          [
            %{
              name: entry_name,
              describe: ~s/def describe(:#{entry_name}), do: "#{escape(entry_description)}"/,
              describe_params: get_param_code_fragments(entry_name, entry_params),
              encode: ~s/def encode(:#{entry_name}), do: #{entry_value_string}/,
              decode: ~s/def decode(:#{enum_name}, #{entry_value_string}), do: :#{entry_name}/
            }
            | details
          ],
          next_value
        }

      end
    )
    reverse(details)
  end
  
  
  @spec get_param_code_fragments(String.t, [Mavlink.Parser.param_description]) :: String.t
  defp get_param_code_fragments(entry_name, entry_params) do
    cond do
      count(entry_params) == 0 ->
        nil
      true ->
        ~s/def describe_params(:#{entry_name}), do: [/ <>
        (map(entry_params, & ~s/{#{&1[:index]}, "#{&1[:description]}"}/) |> join(", ")) <>
        ~s/]/
    end
  end
  
  
  @spec get_message_code_fragments([Mavlink.Parser.message_description], [enum_detail]) :: [ String.t ]
  defp get_message_code_fragments(messages, _enums) do
    for message <- messages do
      module_name = message.name |> module_case
      field_names = message.fields |> map(& ":" <> downcase(&1.name)) |> join(", ")
      field_types = message.fields |> map(& downcase(&1.name) <> ": " <> field_type(&1.type, &1.ordinality, &1.enum)) |> join(", ")
      wire_order = message.fields |> wire_order
      
      # Have to append "_f" to stop clash with reserved elixir words like "end"
      unpack_binary_pattern = wire_order |> map(& downcase(&1.name) <> "_f::" <> type_to_binary(&1.type, &1.ordinality).pattern) |> join(",")
      unpack_struct_fields = message.fields |> map(& downcase(&1.name) <> ": " <> unpack_field_code_fragment(&1)) |> join(", ")
      crc_extra = message |> calculate_message_crc_extra
      expected_payload_size = reduce(message.fields, 0, fn(field, sum) -> sum + type_to_binary(field.type, field.ordinality).size end) # Without Mavlink 2 trailing 0 truncation
      %{
        msg_crc_size:
          """
            def msg_crc_size(#{message.id}), do: {:ok, #{crc_extra}, #{expected_payload_size}}
          """,
        unpack:
          """
            def unpack(#{message.id}, <<#{unpack_binary_pattern}>>), do: {:ok, %Mavlink.#{module_name}{#{unpack_struct_fields}}}
          """,
        module:
          """
          defmodule Mavlink.#{module_name} do
            @moduledoc \"""
            message id:  #{message.id}
            crc extra:   #{crc_extra}
            wire order:  #{wire_order |> map(& &1.name) |> join(", ")}
            \"""
            @enforce_keys [#{field_names}]
            defstruct [#{field_names}]
            @typedoc "#{escape(message.description)}"
            @type t :: %Mavlink.#{module_name}{#{field_types}}
            defimpl Mavlink.Pack do
              def pack(_msg) do
                IO.puts("Packing a #{module_name} message")
              end
            end
          end
          """
      }
    end
  end
  
  # TODO Message 22 PARAM VALUE CRC_EXTRA SHOULD BE 220 BUT IT'S 37, ARRAY PARAMETER
  @spec calculate_message_crc_extra(Mavlink.Parser.message_description) :: 0..255
  defp calculate_message_crc_extra(message) do
    reduce(
      message.fields |> wire_order |> filter(& !&1.is_extension),
      x25_crc(message.name <> " "),
      fn(field, crc) ->
        case field.ordinality do
          1 ->
            crc |> x25_crc(field.type <> " ") |> x25_crc(field.name <> " ")
          _ ->
            crc |> x25_crc(field.type <> " ") |> x25_crc(field.name <> " ") |> x25_crc([field.ordinality])
        end
      end
    ) |> eight_bit_checksum
  end
  
  
  # TODO Decode Bit Fields?
  
  def unpack_field_code_fragment(%{name: name, ordinality: 1, enum: nil}) do
    downcase(name) <> "_f"
  end
  
  def unpack_field_code_fragment(%{name: name, ordinality: 1, enum: enum}) do
    "decode(:#{Atom.to_string(enum)}, #{downcase(name)}_f)" # TODO enums parse as string
  end
  
  def unpack_field_code_fragment(%{name: name, type: "char"}) do
    downcase(name) <> "_f"
  end
  
  def unpack_field_code_fragment(%{name: name, type: type}) do
    "#{downcase(name)}_f |> unpack_array(fn(<<elem::#{type_to_binary(type, 1).pattern},rest::binary>>) ->  {elem, rest} end)"
  end
  
  
  @spec get_unit_code_fragments([Mavlink.Parser.message_description]) :: [ String.t ]
  defp get_unit_code_fragments(messages) do
    reduce(
      messages,
      MapSet.new(),
      fn message, units ->
        reduce(
          message.fields,
          units,
          fn %{units: next_unit}, units ->
            cond do
              next_unit == nil ->
                units
              Regex.match?(~r/^[a-zA-Z0-9@_]+$/, Atom.to_string(next_unit)) ->
                MapSet.put(units, ~s(:#{next_unit}))
              true ->
                MapSet.put(units, ~s(:"#{next_unit}"))
            end
            
          end
        )
      end
    ) |> MapSet.to_list |> Enum.sort
  end
  
  
  @spec module_case(String.t) :: String.t
  defp module_case(name) do
    name
    |> split("_")
    |> map(&capitalize/1)
    |> join("")
  end
  
  
  # Have to deal with some overlap between MAVLink and Elixir types
  defp field_type(type, ordinality, enum) when ordinality == 1, do: field_type(type, enum)
  defp field_type(type, ordinality, enum) when ordinality > 1, do: "[ #{field_type(type, enum)} ]"
  defp field_type(_, enum) when enum != nil, do: "Mavlink.#{Atom.to_string(enum)}"
  defp field_type(:char, _), do: "char"
  defp field_type(:float, _), do: "Float32"
  defp field_type(type, _), do: "Mavlink.#{type}"
  
  
  defp type_to_binary(type, 1), do: type_to_binary(type)
  defp type_to_binary("char", n), do: %{pattern: "binary-size(#{n})", size: n}
  defp type_to_binary("uint8_t", n), do: %{pattern: "binary-size(#{n})", size: n}
  defp type_to_binary("int8_t", n), do: %{pattern: "binary-size(#{n})", size: n}
  defp type_to_binary("uint16_t", n), do: %{pattern: "binary-size(#{n * 2})", size: n * 2}
  defp type_to_binary("int16_t", n), do: %{pattern: "binary-size(#{n * 2})", size: n * 2}
  defp type_to_binary("uint32_t", n), do: %{pattern: "binary-size(#{n * 4})", size: n * 2}
  defp type_to_binary("int32_t", n), do: %{pattern: "binary-size(#{n * 4})", size: n * 4}
  defp type_to_binary("uint64_t", n), do: %{pattern: "binary-size(#{n * 8})", size: n * 8}
  defp type_to_binary("int64_t", n), do: %{pattern: "binary-size(#{n * 8})", size: n * 8}
  defp type_to_binary("float", n), do: %{pattern: "binary-size(#{n * 4})", size: n * 4}
  defp type_to_binary("double", n), do: %{pattern: "binary-size(#{n * 8})", size: n * 8}
  defp type_to_binary("char"), do: %{pattern: "integer-size(8)", size: 1}
  defp type_to_binary("uint8_t"), do: %{pattern: "integer-size(8)", size: 1}
  defp type_to_binary("int8_t"), do: %{pattern: "signed-integer-size(8)", size: 1}
  defp type_to_binary("uint16_t"), do: %{pattern: "little-integer-size(16)", size: 2}
  defp type_to_binary("int16_t"), do: %{pattern: "little-signed-integer-size(16)", size: 2}
  defp type_to_binary("uint32_t"), do: %{pattern: "little-integer-size(32)", size: 4}
  defp type_to_binary("int32_t"), do: %{pattern: "little-signed-integer-size(32)", size: 4}
  defp type_to_binary("uint64_t"), do: %{pattern: "little-integer-size(64)", size: 8}
  defp type_to_binary("int64_t"), do: %{pattern: "little-signed-integer-size(64)", size: 8}
  defp type_to_binary("float"), do: %{pattern: "little-signed-float-size(32)", size: 4}
  defp type_to_binary("double"), do: %{pattern: "little-signed-float-size(64)", size: 8}
  
  
  @spec escape(String.t) :: String.t
  defp escape(s) do
    replace(s, ~s("), ~s(\\"))
  end
  
  
end
