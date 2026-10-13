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
#   anything else — stream “Echo: <text>” in two chunks, stop with “end_turn”
#
# Arguments: --version N  answer initialize with protocol version N
#            --fail-new   answer session/new with an error

require 'json'

$stdout.sync = true

protocol_version = 1
fail_new         = false
args = ARGV.dup
while arg = args.shift
	case arg
	when '--version'  then protocol_version = args.shift.to_i
	when '--fail-new' then fail_new = true
	end
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

next_id         = 1000
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
			send_message('id' => id, 'result' => { 'sessionId' => "sess-#{params['cwd']}" })
		end

	when 'session/prompt'
		session_id = params['sessionId']
		text = (params['prompt'] || []).select { |b| b['type'] == 'text' }.map { |b| b['text'] }.join

		case text
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
