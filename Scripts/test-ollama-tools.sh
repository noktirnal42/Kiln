#!/bin/sh
# Does a local Ollama model make a real, structured tool call? Usage: Scripts/test-ollama-tools.sh <model> [num_ctx]
# Prints the model's advertised capabilities (from /api/show), then asks it to call a tool and shows what came back.
# A model that answers with text such as {"name": ...} instead of tool_calls will not work as an agent in Kiln.
MODEL="${1:?usage: test-ollama-tools.sh <model> [num_ctx]}"
CTX="${2:-8192}"
HOST="${OLLAMA_HOST:-localhost:11434}"
echo "== capabilities"
curl -s -m 20 "http://$HOST/api/show" -d "{\"model\":\"$MODEL\"}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('capabilities'))
print({k:v for k,v in d.get('model_info',{}).items() if k.endswith('context_length')})"
echo "== tool call (the first request loads the model; this can take minutes from a slow disk)"
curl -s -m 600 "http://$HOST/api/chat" -d "{\"model\":\"$MODEL\",\"stream\":false,\"think\":false,\"messages\":[{\"role\":\"user\",\"content\":\"List the files in the project root. Use the tool.\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"list_directory\",\"description\":\"List files in a directory\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}}}],\"options\":{\"num_ctx\":$CTX}}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
m=d.get('message',{})
print('tool_calls:',m.get('tool_calls'))
print('content   :',repr(m.get('content'))[:300])
print('RESULT    :', 'OK, structured tool call' if m.get('tool_calls') else 'NO tool call (text only)')"
