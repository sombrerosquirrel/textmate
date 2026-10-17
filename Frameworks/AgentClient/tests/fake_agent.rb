#!/usr/bin/env ruby
# Minimal Agent Client Protocol agent for AgentClient tests.
#
# Speaks newline-delimited JSON-RPC on stdin/stdout. session/prompt behaviour
# depends on the prompt text:
#
#   “wait”        — don’t answer until session/cancel, then stop with “cancelled”
#   “permission”  — ask the client for permission, echo the outcome
#   “crash”       — exit with status 3 without answering
#   “big”         — stream one 1 MB chunk
#   “stderr”      — write a line to stderr, then answer normally
#   “garbage”     — write a non-JSON line to stdout, then answer normally
#   “read PATH [LINE LIMIT]” — fs/read_text_file, stream “Read: <content>”
#   “write PATH TEXT”        — fs/write_text_file, stream “Wrote”
#   “run COMMAND”            — terminal/create (no args), wait_for_exit,
#                              output, release; stream “Exit: <code> <output>”
#                              (both stream “Error: <code>” on failure, and
#                              “Error: no capability” if the client didn’t
#                              advertise it)
#   anything else — stream “Echo: <text>” in two chunks, stop with “end_turn”
#
# Arguments: --version N  answer initialize with protocol version N
#            --fail-new   answer session/new with an error
#            --exit-early write to stderr and exit with status 1 before initialize

require 'json'

$stdout.sync = true

protocol_version = 1
fail_new         = false
exit_early       = false
args = ARGV.dup
while arg = args.shift
	case arg
	when '--version'  then protocol_version = args.shift.to_i
	when '--fail-new'   then fail_new = true
	when '--exit-early' then exit_early = true
	end
end

if exit_early
	$stderr.puts('fake agent: starting', '', 'fake agent: unsupported Node version')
	exit 1
end

def send_message(msg)
	$stdout.write(JSON.generate(msg.merge('jsonrpc' => '2.0')) + "\n")
end

def update(session_id, update)
	send_message('method' => 'session/update', 'params' => { 'sessionId' => session_id, 'update' => update })
end

def text_chunk(text)
	{ 'sessionUpdate' => 'agent_message_chunk', 'content' => { 'type' => 'text', 'text' => text } }
end

def config_options(mode)
	[{ 'id' => 'mode', 'name' => 'Mode', 'category' => 'mode', 'type' => 'select', 'currentValue' => mode,
	   'options' => [{ 'value' => 'ask', 'name' => 'Ask' }, { 'value' => 'code', 'name' => 'Code' }] }]
end

next_id         = 1000
current_mode    = 'ask'
client_caps     = {}
waiting_prompt  = nil  # id of a prompt waiting for session/cancel
pending_replies = {}   # our request id → proc handling the client’s response

$stdin.each_line do |line|
	msg = JSON.parse(line)

	if msg.key?('result') || msg.key?('error')
		if handler = pending_replies.delete(msg['id'])
			handler.call(msg)
		end
		next
	end

	id, method, params = msg['id'], msg['method'], msg['params'] || {}

	case method
	when 'initialize'
		client_caps = params['clientCapabilities'] || {}
		send_message('id' => id, 'result' => {
			'protocolVersion'   => protocol_version,
			'agentCapabilities' => { 'loadSession' => false, 'promptCapabilities' => { 'embeddedContext' => true } },
			'agentInfo'         => { 'name' => 'fake-agent', 'title' => 'Fake Agent', 'version' => '1.0' },
			'authMethods'       => [],
			'_meta'             => { 'clientInfo' => params['clientInfo'], 'clientCapabilities' => params['clientCapabilities'] },
		})
		send_message('method' => '_fake/hello', 'params' => { 'greeting' => 'hi' })

	when 'session/new'
		if fail_new
			send_message('id' => id, 'error' => { 'code' => -32000, 'message' => 'Authentication required' })
		else
			session_id = "sess-#{params['cwd']}"
			send_message('id' => id, 'result' => {
				'sessionId'     => session_id,
				'configOptions' => config_options(current_mode),
				'modes'         => { 'currentModeId' => current_mode, 'availableModes' => [{ 'id' => 'ask', 'name' => 'Ask' }, { 'id' => 'code', 'name' => 'Code' }] },
			})
			update(session_id, 'sessionUpdate' => 'available_commands_update', 'availableCommands' => [
				{ 'name' => 'plan', 'description' => 'Make a plan', 'input' => { 'hint' => 'what to plan' } },
				{ 'name' => 'review', 'description' => 'Review changes' },
			])
		end

	when 'session/set_config_option'
		if params['configId'] == 'mode' && %w[ask code].include?(params['value'])
			current_mode = params['value']
			send_message('id' => id, 'result' => { 'configOptions' => config_options(current_mode) })
		else
			send_message('id' => id, 'error' => { 'code' => -32602, 'message' => 'Invalid config option' })
		end

	when 'session/set_mode'
		current_mode = params['modeId']
		send_message('id' => id, 'result' => {})
		update(params['sessionId'], 'sessionUpdate' => 'current_mode_update', 'currentModeId' => current_mode)

	when 'session/prompt'
		session_id = params['sessionId']
		text = (params['prompt'] || []).select { |b| b['type'] == 'text' }.map { |b| b['text'] }.join

		ask_client = proc do |method, client_params, &on_result|
			request_id = (next_id += 1)
			pending_replies[request_id] = proc do |reply|
				if reply['error']
					update(session_id, text_chunk("Error: #{reply['error']['code']}"))
				else
					update(session_id, text_chunk(on_result.call(reply['result'])))
				end
				send_message('id' => id, 'result' => { 'stopReason' => 'end_turn' })
			end
			send_message('id' => request_id, 'method' => method, 'params' => client_params.merge('sessionId' => session_id))
		end

		call_client = proc do |method, client_params, &on_reply|
			request_id = (next_id += 1)
			pending_replies[request_id] = on_reply
			send_message('id' => request_id, 'method' => method, 'params' => client_params.merge('sessionId' => session_id))
		end
		finish = proc do |reply_text|
			update(session_id, text_chunk(reply_text))
			send_message('id' => id, 'result' => { 'stopReason' => 'end_turn' })
		end

		case text
		when /\Arun (.+)\z/m
			if client_caps['terminal']
				call_client.call('terminal/create', 'command' => $1) do |created|
					next finish.call("Error: #{created['error']['code']}") if created['error']
					terminal_id = created['result']['terminalId']
					call_client.call('terminal/wait_for_exit', 'terminalId' => terminal_id) do |exited|
						call_client.call('terminal/output', 'terminalId' => terminal_id) do |output|
							call_client.call('terminal/release', 'terminalId' => terminal_id) do
								finish.call("Exit: #{exited['result']['exitCode']} #{output['result']['output']}")
							end
						end
					end
				end
			else
				finish.call('Error: no capability')
			end
		when /\Aread (\S+)(?: (\d+) (\d+))?\z/
			if client_caps.dig('fs', 'readTextFile')
				read_params = { 'path' => $1 }
				read_params.merge!('line' => $2.to_i, 'limit' => $3.to_i) if $2
				ask_client.call('fs/read_text_file', read_params) { |result| "Read: #{result['content']}" }
			else
				update(session_id, text_chunk('Error: no capability'))
				send_message('id' => id, 'result' => { 'stopReason' => 'end_turn' })
			end
		when /\Awrite (\S+) (.*)\z/m
			if client_caps.dig('fs', 'writeTextFile')
				ask_client.call('fs/write_text_file', 'path' => $1, 'content' => $2) { 'Wrote' }
			else
				update(session_id, text_chunk('Error: no capability'))
				send_message('id' => id, 'result' => { 'stopReason' => 'end_turn' })
			end
		when 'wait'
			waiting_prompt = id
			update(session_id, text_chunk('Waiting…'))
		when 'permission'
			request_id = (next_id += 1)
			pending_replies[request_id] = proc do |reply|
				outcome = reply.dig('result', 'outcome') || {}
				update(session_id, text_chunk("Outcome: #{outcome['outcome']} #{outcome['optionId']}".strip))
				send_message('id' => id, 'result' => { 'stopReason' => 'end_turn' })
			end
			send_message('id' => request_id, 'method' => 'session/request_permission', 'params' => {
				'sessionId' => session_id,
				'toolCall'  => { 'toolCallId' => 'call-1', 'title' => 'Write file', 'kind' => 'edit' },
				'options'   => [
					{ 'optionId' => 'allow', 'name' => 'Allow', 'kind' => 'allow_once' },
					{ 'optionId' => 'deny',  'name' => 'Deny',  'kind' => 'reject_once' },
				],
			})
		when 'crash'
			exit 3
		when 'big'
			update(session_id, text_chunk('x' * (1024 * 1024)))
			send_message('id' => id, 'result' => { 'stopReason' => 'end_turn' })
		else
			$stderr.puts('fake agent: stderr line') if text == 'stderr'
			$stdout.write("this is not json\n") if text == 'garbage'
			update(session_id, text_chunk('Echo: '))
			update(session_id, text_chunk(text))
			send_message('id' => id, 'result' => { 'stopReason' => 'end_turn' })
		end

	when 'session/cancel'
		if waiting_prompt
			send_message('id' => waiting_prompt, 'result' => { 'stopReason' => 'cancelled' })
			waiting_prompt = nil
		end

	when '_fake/echo'
		send_message('id' => id, 'result' => params)

	when '_fake/ask_client'
		# Ask the client an unknown method; report the error code it replied with
		request_id = (next_id += 1)
		pending_replies[request_id] = proc { |reply| send_message('id' => id, 'result' => { 'clientError' => reply.dig('error', 'code') }) }
		send_message('id' => request_id, 'method' => 'fs/read_text_file', 'params' => { 'path' => '/tmp/x' })

	else
		send_message('id' => id, 'error' => { 'code' => -32601, 'message' => "Method not found: #{method}" }) if id
	end
end
