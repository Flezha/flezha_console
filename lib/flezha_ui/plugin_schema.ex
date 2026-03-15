defmodule FlezhaUi.PluginSchema do
  def providers() do
    %{
      "processor_websocket" => %{
        label: "WebSocket",
        description: "Connect to a WebSocket server for I/O",
        fields: [
          %{
            name: "uri",
            type: :string,
            required: true,
            label: "URI",
            placeholder: "ws://host:port"
          },
          %{
            name: "post_connect",
            type: :json,
            required: false,
            label: "Post-connect message (JSON)"
          },
          %{name: "ws_opts", type: :json, required: false, label: "WebSocket options (JSON)"},
          %{
            name: "payload_metadata",
            type: :json,
            required: false,
            label: "Payload metadata (JSON)"
          }
        ]
      },
      "kafka" => %{
        label: "Kafka Producer",
        description: "Produce messages to a Kafka topic",
        fields: [
          %{
            name: "hosts",
            type: :string,
            required: true,
            label: "Broker hosts",
            placeholder: "localhost:9092"
          },
          %{name: "topic", type: :string, required: true, label: "Topic"},
          %{name: "partition", type: :integer, required: false, label: "Partition"},
          %{name: "required_acks", type: :integer, required: false, label: "Required acks"}
        ]
      },
      "filter" => %{
        label: "Filter",
        description: "Filter messages by regex pattern",
        fields: [
          %{name: "regex_pattern", type: :string, required: true, label: "Regex pattern"},
          %{
            name: "inverted",
            type: :boolean,
            required: false,
            label: "Inverted (pass non-matching)"
          }
        ]
      },
      "stdout" => %{
        label: "Stdout",
        description: "Print messages to stdout (debugging)",
        fields: []
      }
    }
  end

  def provider(id), do: Map.get(providers(), id)
end
