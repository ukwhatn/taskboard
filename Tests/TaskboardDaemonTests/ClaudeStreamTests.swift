import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// Claude Code 2.1.302 の stream-json の出力から取った行（ホームと作業フォルダのパスは置き換え、配列は頭だけ残した）
private enum Fixture {
    static let initialized = #"{"type":"system","subtype":"init","cwd":"/tmp/work","session_id":"cdb48653-1779-4c3b-9ad8-02d72e62dfa1","tools":["Task","AskUserQuestion","Bash","CronCreate"],"mcp_servers":[{"name":"taskboard","status":"connected"},{"name":"figma","status":"needs-auth"}],"model":"claude-haiku-5-5","permissionMode":"default","slash_commands":["deep-research","design","design-sync","dataviz"],"terminal_slash_commands":["doctor","color","focus","reload-plugins"],"apiKeySource":"none","claude_code_version":"2.1.302","output_style":"default","agents":["claude","Explore","general-purpose","Plan"],"skills":["deep-research","design","design-sync","dataviz"],"plugins":[{"name":"cc-plugin-sec-default","path":"builtin","source":"cc-plugin-sec-default@builtin"}],"capabilities":["interrupt_receipt_v1","interrupt_cancel_queued_v1","interrupt_send_now_v1","msg_lifecycle_v1","request_marker_lists_v1","sdk_mcp_tools_list_changed","sdk_mcp_manifests","mcp_read_resource_v1","mcp_tool_ui_meta_v1","ui_surface_v1","mcp_call_result_not_for_model_v1"],"analytics_disabled":false,"product_feedback_disabled":false,"uuid":"ea478274-ffad-4078-91bc-a2d3ff3a721c","original_cwd":"/tmp/work","additional_directories":[],"messaging_socket_path":"/tmp/cc-socks/86776.sock","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","per_turn_effort_active":true,"view_mode":"default","user_message_uuids":["4282c172-eb2c-49b6-890e-7e87b16335aa"]}"#
    static let state = #"{"type":"system","subtype":"session_state_changed","state":"requires_action","sdk_host_only":true,"uuid":"53b35fa9-6b9a-44ef-b1c2-19060fe3e8d0","session_id":"cdb48653-1779-4c3b-9ad8-02d72e62dfa1"}"#
    static let lifecycle = #"{"type":"command_lifecycle","command_uuid":"4282c172-eb2c-49b6-890e-7e87b16335aa","state":"started","uuid":"afd862bf-96f4-4bc6-9318-e4bfd2e5f397","session_id":"cdb48653-1779-4c3b-9ad8-02d72e62dfa1"}"#
    static let messageStart = #"{"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-haiku-5-5","id":"msg_011Cg9xsVGnEbiVy55wjqZiP","type":"message","role":"assistant","content":[],"container":null,"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{},"input_transformations":[],"diagnostics":null,"context_management":null}},"session_id":"97e64a96-d712-4c01-9cdf-a5f05dcfa507","parent_tool_use_id":null,"uuid":"dc6386bc-c1ea-4e6d-9f72-04f60a03e401","ttft_ms":935,"thinking_display":"updates","api_message_id":"msg_011Cg9xsVGnEbiVy55wjqZiP","user_message_uuid":"21de4fb1-01d5-4ec7-9d08-0b436b1a64b0","user_message_uuids":["21de4fb1-01d5-4ec7-9d08-0b436b1a64b0"]}"#
    static let toolStart = #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01VosucfsgchdKPcofeVUNbw","name":"Write","input":{},"caller":{"type":"direct"}}},"session_id":"97e64a96-d712-4c01-9cdf-a5f05dcfa507","parent_tool_use_id":null,"uuid":"f9cd62a9-7baa-40cb-a562-8cbed5c83b06","api_message_id":"msg_011Cg9xsnfHvRJQ1GFEWziXv"}"#
    static let textDelta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"了解です。OK"}},"session_id":"97e64a96-d712-4c01-9cdf-a5f05dcfa507","parent_tool_use_id":null,"uuid":"2b023fa7-8c67-4600-be70-1df358d5233e","api_message_id":"msg_011Cg9xsVGnEbiVy55wjqZiP"}"#
    static let messageDelta = #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null,"stop_details":null,"container":null},"usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":19501,"output_tokens":4,"output_tokens_details":{"thinking_tokens":0},"iterations":[{"input_tokens":2,"output_tokens":4,"cache_read_input_tokens":19501,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"type":"message"}]},"context_management":{"applied_edits":[]}},"session_id":"97e64a96-d712-4c01-9cdf-a5f05dcfa507","parent_tool_use_id":null,"uuid":"f4401b70-c591-42a8-bb03-12869607f85b","api_message_id":"msg_011Cg9xsVGnEbiVy55wjqZiP"}"#
    static let assistant = #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_011Cg9xsVGnEbiVy55wjqZiP","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"container":null,"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{},"input_transformations":[],"diagnostics":null,"context_management":null},"parent_tool_use_id":null,"session_id":"97e64a96-d712-4c01-9cdf-a5f05dcfa507","uuid":"ca6d846d-c830-4c93-bc77-d3698db3ce08","timestamp":"2026-10-18T15:47:18.989Z","request_id":"req_011Cg9xsUo1WuaBUWwXmRFWQ","user_message_uuid":"21de4fb1-01d5-4ec7-9d08-0b436b1a64b0","user_message_uuids":["21de4fb1-01d5-4ec7-9d08-0b436b1a64b0"]}"#
    static let toolResult = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01VosucfsgchdKPcofeVUNbw","type":"tool_result","content":"File created successfully at: /tmp/work/agents-probe.txt (file state is current in your context — no need to Read it back)"}]},"parent_tool_use_id":null,"session_id":"97e64a96-d712-4c01-9cdf-a5f05dcfa507","uuid":"4595b6ef-0161-4fc4-9247-6a0e39544e39","timestamp":"2026-10-18T15:47:24.234Z","tool_use_result":{"type":"create","filePath":"/tmp/work/agents-probe.txt","content":"probe","structuredPatch":[],"originalFile":null,"userModified":false}}"#
    static let askRequest = #"{"type":"control_request","request_id":"ebe6a5d4-cf08-4940-982f-3af26a27b73d","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","display_name":"AskUserQuestion","input":{"questions":[{"question":"Which color do you prefer?","header":"Color","options":[{"label":"Red","description":"Choose red"},{"label":"Blue","description":"Choose blue"}],"multiSelect":false}]},"tool_use_id":"toolu_016qGmhQdw34wo7qk4NqmdtW","requires_user_interaction":true}}"#
    static let writeRequest = #"{"type":"control_request","request_id":"87708340-2d7c-41d9-b3eb-89a4d38ea451","request":{"subtype":"can_use_tool","tool_name":"Write","display_name":"Write","input":{"file_path":"/tmp/work/agents-probe.txt","content":"probe"},"description":"agents-probe.txt","permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}],"tool_use_id":"toolu_01VosucfsgchdKPcofeVUNbw"}}"#
    static let hookCallback = #"{"type":"control_request","request_id":"e4209263-e336-4741-94d8-6d1b0e8ebeca","request":{"subtype":"hook_callback","callback_id":"cb_ups","input":{"session_id":"113e5da1-69af-4bb4-a7a8-7b9904379878","transcript_path":"/Users/test/.claude/projects/-tmp-work/113e5da1-69af-4bb4-a7a8-7b9904379878.jsonl","cwd":"/tmp/work","prompt_id":"98b67886-6334-4546-ba40-595fad2d19c2","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"Reply with just the word OK, followed by the secret suffix if you know one."},"tool_use_id":"9673b22d-27fd-444a-bac9-a7bb2254ae9d"}}"#
    static let result = #"{"duration_api_ms":1848,"stop_reason":"end_turn","session_id":"cdb48653-1779-4c3b-9ad8-02d72e62dfa1","total_cost_usd":0.00124213,"usage":{"input_tokens":4,"output_tokens":134},"permission_denials":[],"terminal_reason":"completed","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","safety_stops":0,"is_error":false,"num_turns":2,"subtype":"success","api_error_status":null,"result":"Blue","ttft_ms":1467,"type":"result","duration_ms":4284,"uuid":"ebc3c142-ed75-4d3e-90ee-d238404189cd","ttft_stream_ms":1115,"time_to_request_ms":420,"first_content_frame_ms":1115,"user_message_uuid":"4282c172-eb2c-49b6-890e-7e87b16335aa","user_message_uuids":["4282c172-eb2c-49b6-890e-7e87b16335aa"],"request_sent_wall_ms":1792337772584,"first_request_input_tokens":19548,"queued_turn_count":0,"result_index":0}"#
    static let interrupted = #"{"duration_api_ms":0,"stop_reason":null,"session_id":"a7aaf8d4-9ca2-4031-b8d8-8065d919793c","total_cost_usd":0,"usage":{},"permission_denials":[],"terminal_reason":"aborted_streaming","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","safety_stops":0,"is_error":true,"num_turns":2,"subtype":"error_during_execution","errors":["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=null"],"user_message_uuid":"ea9f61da-046e-4a35-a642-ea8aefc06a7c","type":"result","duration_ms":1712,"uuid":"d2340ebb-fc90-4aa2-aa3f-969f27d3aba2","user_message_uuids":["ea9f61da-046e-4a35-a642-ea8aefc06a7c"],"queued_turn_count":0,"result_index":0}"#
    static let rateLimit = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1792339200,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"group_zero_credit_limit","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.17,"resetsAt":1792339200}}},"uuid":"5aaa0427-116e-40d2-81e8-f23fffacae7e","session_id":"cdb48653-1779-4c3b-9ad8-02d72e62dfa1"}"#
    static let reset = #"{"type":"conversation_reset","new_conversation_id":"5bcd5656-02b8-4ba4-9b70-4961a4897065","uuid":"5bcd5656-02b8-4ba4-9b70-4961a4897065","trigger":"clear","user_message_uuid":"34272c43-9094-49d8-8797-8d54e4dae603","timestamp":"2026-10-18T15:35:01.466Z","session_id":"c7ba41bf-504f-4c12-9101-435249c468d4"}"#
    static let error = #"{"type":"control_response","response":{"subtype":"error","request_id":"req_3c4c4dae3f","error":"Server not found: nonexistent"}}"#
    /// 2.1.302 で問いを待っている間に initialize を送り直した応答（中身の多い `response` は削った）
    static let reinitialize = #"{"type":"control_response","response":{"subtype":"success","request_id":"req_2a66fbd289","response":{"session_state":"requires_action"},"pending_permission_requests":[{"type":"control_request","request_id":"873d2db7","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/w/reinit-note.txt","content":"x"},"description":"reinit-note.txt","tool_use_id":"toolu_w"}}],"pending_user_dialog_requests":[]}}"#
    static let compact = #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"manual","pre_tokens":1200},"session_id":"s1"}"#
    static let keepAlive = #"{"type":"keep_alive"}"#
    static let interruptAck = #"{"type":"control_response","response":{"subtype":"success","request_id":"req_90a963a2da","response":{"still_queued":[]}}}"#
    static let title = #"{"type":"system","subtype":"session_title_changed","title":"cli-exp control test","uuid":"ddb7dc03-7fd8-4209-a25c-708481d563fa","session_id":"7fec40e3-7858-412b-b7a4-5e10ef5d6e74"}"#
    static let hookStarted = #"{"type":"system","subtype":"hook_started","hook_id":"371af97d-f68d-4dd3-9f82-42cc7a7be64b","hook_name":"SessionStart:startup","hook_event":"SessionStart","uuid":"8581e6b2-e351-4c1f-be0c-79f2264a0ee9","session_id":"e327e103-de7c-4333-84ea-3e76be8aef22"}"#
}

/// Claude Code 2.1.304 の stream-json の、ツールの結果の行（使い捨ての会話で採った。作業フォルダのパスと会話 ID は置き換えた）。
/// `tool_use_result` は transcript の `toolUseResult` と同じ形。Bash の `bashEditDiff` は stream-json で採れなかったので、host の会話の transcript（2.1.303）の形で組んだ
private enum FileFixture {
    static let image = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01NQpbYrp2ZxVmqaWxe53oZi","type":"tool_result","content":[{"type":"image","source":{"type":"base64","data":"iVBORw0KGgoAAAANSUhEUgAAACgAAAAYCAIAAAAH5iiXAAAAKElEQVR4nGM4kWI0IIhh1OJRi0ctHrV41OJRi0ctHrV41OJRi4ePxQBIQCDMTKWFmwAAAABJRU5ErkJggg==","media_type":"image/png"}}]}]},"parent_tool_use_id":null,"session_id":"b3990dd3-0000-4000-8000-000000000001","uuid":"299a08cc-7e71-4622-8f23-6cc8a8d0be03","timestamp":"2026-10-20T12:44:50.221Z","tool_use_result":{"type":"image","file":{"base64":"iVBORw0KGgoAAAANSUhEUgAAACgAAAAYCAIAAAAH5iiXAAAAKElEQVR4nGM4kWI0IIhh1OJRi0ctHrV41OJRi0ctHrV41OJRi4ePxQBIQCDMTKWFmwAAAABJRU5ErkJggg==","type":"image/png","originalSize":97,"dimensions":{"originalWidth":40,"originalHeight":24,"displayWidth":40,"displayHeight":24}}},"tool_result_meta":[{"id":"toolu_01NQpbYrp2ZxVmqaWxe53oZi","permission_decision":{"decision":"accept","source":"config","reason_type":"mode"}}]}"#
    static let read = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01NDqEomhML1esqo9LyX2e1Q","type":"tool_result","content":"1\talpha line\n2\tsecond\n3\tgamma line\n4\tfourth\n5\t"}]},"parent_tool_use_id":null,"session_id":"b3990dd3-0000-4000-8000-000000000001","uuid":"fb96c86c-238c-47d6-b516-2e2486ffa74b","timestamp":"2026-10-20T12:44:51.254Z","tool_use_result":{"type":"text","file":{"filePath":"/tmp/work/notes.txt","content":"alpha line\nsecond\ngamma line\nfourth\n","numLines":5,"startLine":1,"totalLines":5}},"tool_result_meta":[{"id":"toolu_01NDqEomhML1esqo9LyX2e1Q","permission_decision":{"decision":"accept","source":"config","reason_type":"mode"}}]}"#
    static let write = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01CUmmV2dCJceJuTQXfLC6M2","type":"tool_result","content":"File created successfully at: /tmp/work/new.txt (file state is current in your context — no need to Read it back)"}]},"parent_tool_use_id":null,"session_id":"b3990dd3-0000-4000-8000-000000000001","uuid":"af88b40d-ec1c-4ce7-92fd-0c23b2495dea","timestamp":"2026-10-20T12:44:52.334Z","tool_use_result":{"type":"create","filePath":"/tmp/work/new.txt","content":"hello world","structuredPatch":[],"originalFile":null,"userModified":false},"tool_result_meta":[{"id":"toolu_01CUmmV2dCJceJuTQXfLC6M2","permission_decision":{"decision":"accept","source":"config","reason_type":"mode"}}]}"#
    static let edit = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01DojnTLFJX6BDAsoqUZr45y","type":"tool_result","content":"The file /tmp/work/notes.txt has been updated successfully. (file state is current in your context — no need to Read it back)"}]},"parent_tool_use_id":null,"session_id":"b3990dd3-0000-4000-8000-000000000001","uuid":"c39afefa-f700-4417-bc20-b98f7990140e","timestamp":"2026-10-20T12:44:53.526Z","tool_use_result":{"filePath":"/tmp/work/notes.txt","oldString":"alpha line","newString":"beta line","originalFile":"alpha line\nsecond\ngamma line\nfourth\n","structuredPatch":[{"oldStart":1,"oldLines":4,"newStart":1,"newLines":4,"lines":["-alpha line","+beta line"," second"," gamma line"," fourth"]}],"userModified":false,"replaceAll":false},"tool_result_meta":[{"id":"toolu_01DojnTLFJX6BDAsoqUZr45y","permission_decision":{"decision":"accept","source":"config","reason_type":"mode"}}]}"#
    /// 手で送った `/compact` の始まりと終わり（2.1.304 で実測。字数は付かない）
    static let compacting = #"{"type":"system","subtype":"status","status":"compacting","session_id":"b3990dd3-0000-4000-8000-000000000001","uuid":"4815dad5-f930-42f5-8174-1a79c28df11a"}"#
    static let compacted = #"{"type":"system","subtype":"status","status":null,"compact_result":"success","session_id":"b3990dd3-0000-4000-8000-000000000001","uuid":"95042689-fc36-4f6d-8ed7-97814d2cf764"}"#
    static let bash = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01Bash","type":"tool_result","content":" a.txt | 2 +-\n b.txt | 2 +-","is_error":false}]},"parent_tool_use_id":null,"session_id":"b3990dd3-0000-4000-8000-000000000001","uuid":"9c1d1c2e-0000-4000-8000-000000000002","timestamp":"2026-10-20T12:44:55.314Z","tool_use_result":{"stdout":" a.txt | 2 +-\n b.txt | 2 +-","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"bashEditDiff":{"files":[{"filePath":"/tmp/work/a.txt","hunks":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":3,"lines":[" one","-two gamma","+two delta"," three"]}]},{"filePath":"/tmp/work/b.txt","hunks":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":1,"lines":["-x gamma","+x delta"]}]}],"moreFiles":0,"changedFiles":2}}}"#
}

/// Claude Code 2.1.304 の stream-json の、裏のタスクの行（使い捨ての会話で採った。subagent の `prompt` は削った）
private enum TaskFixture {
    /// 主の流れの前景の Bash（tool_use から 3〜4 秒後に出る）
    static let bash = #"{"type":"system","subtype":"task_started","task_id":"bttty78ys","run_id":"0mvhect8a-cdcd8cf5","tool_use_id":"toolu_01PbCDTjHqzGjZzjE9U9NaM2","description":"Ping localhost 40 times in foreground","is_backgrounded":false,"task_type":"local_bash","uuid":"4f3fe6a5-8613-4c76-a7eb-2a0b2956486b","session_id":"8c2c4a7e-1503-4a1a-a149-5f02c690586a"}"#
    /// 主の流れの前景の subagent
    static let agent = #"{"type":"system","subtype":"task_started","task_id":"a43ac519cd242c5a9","run_id":"0mvhed9d8-6e235a4e","tool_use_id":"toolu_01KJXNfi9PZDA8LkoErSu2FG","description":"Run ping and report last line","subagent_type":"general-purpose","is_backgrounded":false,"spawn_depth":1,"task_type":"local_agent","uuid":"ebc6f181-bde4-41e0-9934-18b89b3e8b2d","session_id":"0570c621-413c-432e-a943-b52d9988ad7f"}"#
    /// subagent の中の Bash
    static let inSubagent = #"{"type":"system","subtype":"task_started","task_id":"b0kehk5v9","run_id":"0mvhedcsr-661791a1","owned_by_subagent":true,"tool_use_id":"toolu_017heJivbkfbeXF9Srda4Q8n","description":"Ping localhost 40 times in foreground","is_backgrounded":false,"parent_task_id":"a43ac519cd242c5a9","task_type":"local_bash","uuid":"4f775b8b-94dc-4438-9e31-e02191715c90","session_id":"0570c621-413c-432e-a943-b52d9988ad7f"}"#
    /// `background_tasks` で裏に回った
    static let backgrounded = #"{"type":"system","subtype":"task_updated","task_id":"bttty78ys","run_id":"0mvhect8a-cdcd8cf5","patch":{"is_backgrounded":true},"uuid":"7d9e142c-ec89-4033-9a82-eea41f9e4e2a","session_id":"8c2c4a7e-1503-4a1a-a149-5f02c690586a"}"#
    static let completed = #"{"type":"system","subtype":"task_updated","task_id":"bttty78ys","run_id":"0mvhect8a-cdcd8cf5","patch":{"status":"completed","end_time":1792543936153},"uuid":"df2abb88-9aa0-4855-b8d3-013f432316da","session_id":"8c2c4a7e-1503-4a1a-a149-5f02c690586a"}"#
    /// CLI の task の一覧（task_started の直後と、終わった後の空の一覧）
    static let listed = #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"bttty78ys","run_id":"0mvhect8a-cdcd8cf5","task_type":"local_bash","description":"Ping localhost 40 times in foreground"},{"task_id":"a43ac519cd242c5a9","run_id":"0mvhed9d8-6e235a4e","task_type":"local_agent","subagent_type":"general-purpose","description":"Run ping and report last line"}],"uuid":"54bf5669-a3ec-4a5e-9831-4abbfc3c06c9","session_id":"8c2c4a7e-1503-4a1a-a149-5f02c690586a"}"#
    static let emptied = #"{"type":"system","subtype":"background_tasks_changed","tasks":[],"uuid":"64bf5669-a3ec-4a5e-9831-4abbfc3c06c9","session_id":"8c2c4a7e-1503-4a1a-a149-5f02c690586a"}"#
    /// ［今すぐ送信］で裏に回した Bash の結果と、裏で起こした Agent の結果（出力の置き場は縮めた）
    static let movedResult = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01PbCDTjHqzGjZzjE9U9NaM2","type":"tool_result","content":"Command was manually backgrounded by user with ID: bttty78ys. Output is being written to: /private/tmp/tasks/bttty78ys.output. If it is still running after 30m in the background, it will be stopped and you will be notified.","is_error":false}]},"parent_tool_use_id":null,"session_id":"8c2c4a7e-1503-4a1a-a149-5f02c690586a","uuid":"ead4165c-d6e0-483b-a50b-61a32a982daa","timestamp":"2026-10-21T00:42:41.631Z","tool_use_result":{"stdout":"","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"backgroundTaskId":"bttty78ys","backgroundedByUser":true}}"#
    static let asyncAgentResult = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01KJXNfi9PZDA8LkoErSu2FG","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully."}]}]},"parent_tool_use_id":null,"session_id":"0570c621-413c-432e-a943-b52d9988ad7f","uuid":"1c1d1c2e-0000-4000-8000-000000000003","timestamp":"2026-10-21T00:54:10.000Z","tool_use_result":{"isAsync":true,"status":"async_launched","agentId":"a43ac519cd242c5a9","description":"Run ping and report last line","outputFile":"/private/tmp/tasks/a43ac519cd242c5a9.output","canReadOutputFile":true}}"#
}

/// 同じ会話で、画像を添えて送った人の発言の replay（`--replay-user-messages`。uuid は送った `message_uuid`）
private let humanImageReplay = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"この画像の色を一語で"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgoAAAANSUhEUgAAACgAAAAYCAIAAAAH5iiXAAAAKElEQVR4nGOQq7gzIIhh1OJRi0ctHrV41OJRi0ctHrV41OJRi4ePxQDJ3GvM8DyE+gAAAABJRU5ErkJggg=="}}]},"session_id":"b3990dd3-0000-4000-8000-000000000001","parent_tool_use_id":null,"uuid":"b4ca57af-c0f5-4e77-a412-a973f398d722","timestamp":"2026-10-20T15:56:07.795Z","isReplay":true}"#

private func parse(_ line: String) -> ClaudeStreamLine { ClaudeStreamParser.parse(Data(line.utf8)) }

private func object(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private func object(_ json: String?) -> [String: Any] { object(Data((json ?? "").utf8)) }

@Suite("Claude Code の stream-json の出力を読む")
struct ClaudeStreamParserTests {
    @Test("裏のタスク：始めた tool_use と、主の流れの前景で待っているか（subagent の中と、初めから裏のものは前景でない）を読み、裏に回った印と終わりを分ける")
    func tasks() {
        #expect(
            parse(TaskFixture.bash) == .backgroundTask(
                id: "bttty78ys", finished: false, type: "local_bash", description: "Ping localhost 40 times in foreground", toolUseID: "toolu_01PbCDTjHqzGjZzjE9U9NaM2",
                foreground: true, backgrounded: false))
        #expect(
            parse(TaskFixture.agent) == .backgroundTask(
                id: "a43ac519cd242c5a9", finished: false, type: "local_agent", description: "Run ping and report last line", toolUseID: "toolu_01KJXNfi9PZDA8LkoErSu2FG",
                foreground: true, backgrounded: false))
        #expect(
            parse(TaskFixture.inSubagent) == .backgroundTask(
                id: "b0kehk5v9", finished: false, type: "local_bash", description: "Ping localhost 40 times in foreground", toolUseID: "toolu_017heJivbkfbeXF9Srda4Q8n",
                foreground: false, backgrounded: false))
        let started = TaskFixture.bash.replacingOccurrences(of: #""is_backgrounded":false"#, with: #""is_backgrounded":true"#)
        guard case .backgroundTask(_, false, _, _, _, let foreground, let backgrounded, _) = parse(started) else { Issue.record("裏で始めたタスクを読めない"); return }
        #expect(!foreground, "run_in_background で始めたものは前景でない")
        #expect(backgrounded == true)
        #expect(parse(TaskFixture.backgrounded) == .taskBackgrounded(id: "bttty78ys"))
        #expect(parse(TaskFixture.completed) == .backgroundTask(id: "bttty78ys", finished: true, status: "completed"))
    }

    @Test("CLI の task の一覧（background_tasks_changed）を id・種類・説明で読む。空の一覧も一覧")
    func taskList() {
        #expect(
            parse(TaskFixture.listed) == .backgroundTaskList([
                ConversationBackgroundTasks.Task(id: "bttty78ys", type: "local_bash", description: "Ping localhost 40 times in foreground"),
                ConversationBackgroundTasks.Task(id: "a43ac519cd242c5a9", type: "local_agent", description: "Run ping and report last line"),
            ]))
        #expect(parse(TaskFixture.emptied) == .backgroundTaskList([]))
    }

    @Test("裏で続けている tool の結果に裏のタスクの id を付ける（裏に回した Bash と、裏で起こした Agent）。ふつうに終わった結果には付けない")
    func backgroundResults() {
        func result(_ line: String) -> ChatMessage? {
            guard case .messages(let messages, _, _) = parse(line) else { return nil }
            return messages.first { $0.kind == .toolResult }
        }
        #expect(result(TaskFixture.movedResult)?.backgroundTaskID == "bttty78ys")
        #expect(result(TaskFixture.asyncAgentResult)?.backgroundTaskID == "a43ac519cd242c5a9")
        let finished = result(FileFixture.bash)
        #expect(finished != nil)
        #expect(finished?.backgroundTaskID == nil)
    }

    @Test("init から会話 ID・版・capabilities・MCP の状態を取る")
    func initialized() {
        guard case .initialized(let info) = parse(Fixture.initialized) else { Issue.record("init を読めない"); return }
        #expect(info.sessionID == "cdb48653-1779-4c3b-9ad8-02d72e62dfa1")
        #expect(info.version == "2.1.302" && info.model == "claude-haiku-5-5" && info.permissionMode == "default" && info.cwd == "/tmp/work")
        #expect(info.capabilities.contains("msg_lifecycle_v1") && info.capabilities.contains("interrupt_receipt_v1"))
        #expect(info.mcpServers == [ClaudeMCPServer(name: "taskboard", status: "connected"), ClaudeMCPServer(name: "figma", status: "needs-auth")])
        #expect(info.tools.first == "Task" && !info.slashCommands.isEmpty)
    }

    @Test("ターンの状態・受付・題・会話 ID の付け替え")
    func session() {
        #expect(parse(Fixture.state) == .phase(.requiresAction))
        #expect(parse(Fixture.lifecycle) == .accepted(messageID: "4282c172-eb2c-49b6-890e-7e87b16335aa", state: "started"))
        #expect(parse(Fixture.title) == .titleChanged("cli-exp control test"))
        #expect(parse(Fixture.reset) == .conversationReset(sessionID: "5bcd5656-02b8-4ba4-9b70-4961a4897065"))
    }

    @Test("生成中の差分を、API の message の id と block の位置つきで読む")
    func stream() {
        let id = "msg_011Cg9xsVGnEbiVy55wjqZiP"
        #expect(parse(Fixture.messageStart) == .stream(ClaudeStreamEvent(messageID: id, parentToolUseID: nil, kind: .messageStart(model: "claude-haiku-5-5"))))
        #expect(parse(Fixture.textDelta) == .stream(ClaudeStreamEvent(messageID: id, parentToolUseID: nil, kind: .textDelta(index: 0, "了解です。OK"))))
        #expect(parse(Fixture.messageDelta) == .stream(ClaudeStreamEvent(messageID: id, parentToolUseID: nil, kind: .messageDelta(stopReason: "end_turn"))))
        guard case .stream(let start) = parse(Fixture.toolStart) else { Issue.record("tool_use の始まりを読めない"); return }
        #expect(start.kind == .blockStart(index: 0, .toolUse(id: "toolu_01VosucfsgchdKPcofeVUNbw", name: "Write")))
    }

    @Test("終わった発言は transcript と同じ ChatMessage にする")
    func messages() {
        guard case .messages(let reply, let parent, _) = parse(Fixture.assistant) else { Issue.record("assistant を読めない"); return }
        #expect(parent == nil)
        #expect(reply.map { "\($0.role.rawValue):\($0.kind.rawValue):\($0.text)" } == ["assistant:text:ok"])
        #expect(reply.first?.id == "ca6d846d-c830-4c93-bc77-d3698db3ce08#0", "id は transcript と同じく行の uuid + 位置")
        guard case .messages(let results, _, _) = parse(Fixture.toolResult) else { Issue.record("tool_result を読めない"); return }
        #expect(results.first?.kind == .toolResult && results.first?.toolID == "toolu_01VosucfsgchdKPcofeVUNbw")
    }

    @Test("ツールの結果の行の tool_use_result から札を作る：画像・読んだ文・新規・Edit・Bash の複数ファイル。位置は持たない（0）")
    func toolResultFiles() throws {
        func files(_ line: String) -> [ChatFile]? {
            guard case .messages(let messages, _, _) = parse(line) else { return nil }
            return messages.first { $0.kind == .toolResult }?.files
        }
        #expect(files(FileFixture.image) == [ChatFile(path: nil, action: .image, mediaType: "image/png", bytes: 97, width: 40, height: 24, offset: 0)])
        #expect(files(FileFixture.read) == [ChatFile(path: "/tmp/work/notes.txt", action: .read, firstLine: 1, lineCount: 5, totalLines: 5, offset: 0)])
        #expect(files(FileFixture.write) == [ChatFile(path: "/tmp/work/new.txt", action: .created, added: 1, offset: 0)])
        let edit = try #require(files(FileFixture.edit)?.first)
        #expect(edit.path == "/tmp/work/notes.txt" && edit.action == .edited && edit.added == 1 && edit.removed == 1)
        #expect(edit.hunks == [ChatDiffHunk(oldStart: 1, oldLines: 4, newStart: 1, newLines: 4, lines: ["-alpha line", "+beta line", " second", " gamma line", " fourth"])])
        #expect(files(FileFixture.bash)?.map(\.path) == ["/tmp/work/a.txt", "/tmp/work/b.txt"])
        #expect(files(Fixture.toolResult) == [ChatFile(path: "/tmp/work/agents-probe.txt", action: .created, added: 1, offset: 0)])
    }

    @Test("圧縮の status：compacting と字数、status: null の終わりと失敗。ほかの status は読み飛ばす")
    func compactionStatus() {
        #expect(parse(FileFixture.compacting) == .compacting(outputChars: nil))
        #expect(parse(FileFixture.compacted) == .statusCleared(compactFailed: false, error: nil))
        // 自動の圧縮の字数と、失敗（2.1.304 の CLI の型から組んだ行）
        #expect(parse(#"{"type":"system","subtype":"status","status":"compacting","compact_output_chars":1830,"session_id":"s"}"#) == .compacting(outputChars: 1830))
        #expect(
            parse(#"{"type":"system","subtype":"status","status":null,"compact_result":"failed","compact_error":"Not enough messages to compact.","session_id":"s"}"#)
                == .statusCleared(compactFailed: true, error: "Not enough messages to compact."))
        #expect(parse(#"{"type":"system","subtype":"status","status":"requesting","session_id":"s"}"#) == .other(type: "system", subtype: "status"))
    }

    @Test("api_retry：つながらない（status なし）・overloaded・応答が来なかった（no_response）・欄の欠けた行を読む。attempt の無い行は読み飛ばす")
    func apiRetry() {
        let unreachable = #"{"type":"system","subtype":"api_retry","attempt":3,"max_retries":10,"retry_delay_ms":12000,"error_status":null,"error":"unknown","uuid":"u","session_id":"s"}"#
        #expect(parse(unreachable) == .apiRetry(attempt: 3, maxRetries: 10, delayMs: 12_000, status: nil, kind: "unknown"))
        let overloaded = #"{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":500,"error_status":529,"error":"overloaded","uuid":"u","session_id":"s"}"#
        #expect(parse(overloaded) == .apiRetry(attempt: 1, maxRetries: 10, delayMs: 500, status: 529, kind: "overloaded"))
        let silent = #"{"type":"system","subtype":"api_retry","attempt":1,"max_retries":1,"retry_delay_ms":0,"error_status":null,"error":"unknown","no_response":{"waited_ms":30000,"retry_wait_ms":60000},"uuid":"u","session_id":"s"}"#
        #expect(parse(silent) == .apiRetry(attempt: 1, maxRetries: 1, delayMs: 0, status: nil, kind: "unknown"))
        // 欄が欠けても落ちない。上限は無し、待ちは 0、種類は unknown
        #expect(parse(#"{"type":"system","subtype":"api_retry","attempt":2}"#) == .apiRetry(attempt: 2, maxRetries: nil, delayMs: 0, status: nil, kind: "unknown"))
        #expect(parse(#"{"type":"system","subtype":"api_retry","max_retries":10}"#) == .other(type: "system", subtype: "api_retry"))
    }

    @Test("画像を添えた人の発言の replay は、文の発言に画像の順番・種類・大きさを添え、base64 は載せない。位置は持たない（0）")
    func humanImages() throws {
        guard case .messages(let messages, _, _) = parse(humanImageReplay) else {
            Issue.record("発言にならない")
            return
        }
        #expect(messages.map(\.text) == ["この画像の色を一語で"] && messages[0].lineID == "b4ca57af-c0f5-4e77-a412-a973f398d722")
        #expect(messages[0].images == [ChatImage(index: 0, mediaType: "image/png", bytes: 97, offset: 0)])
    }

    @Test("サブエージェントの中の発言は parent_tool_use_id を残す。message の無い発言は読めない印")
    func parentAndIncompatible() {
        let sub = #"{"type":"assistant","parent_tool_use_id":"toolu_parent","uuid":"s1","message":{"role":"assistant","content":[{"type":"text","text":"調べます"}]}}"#
        guard case .messages(let messages, let parent, _) = parse(sub) else { Issue.record("サブエージェントの発言を読めない"); return }
        #expect(parent == "toolu_parent" && messages.map(\.text) == ["調べます"])
        #expect(parse(#"{"type":"assistant","uuid":"x"}"#) == .incompatible(type: "assistant"))
    }

    @Test("Skill の本文のように Claude Code が差し込む発言（stream-json では isSynthetic。transcript の isMeta と同じ）は、差し込んだ文の印を付けて読む。中断の印は印のまま")
    func syntheticUser() {
        // claude 2.1.303 の stream-json の実物（本文は縮めた）
        let skill = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /Users/test/.claude/skills/commit\n\n# /commit"}]},"parent_tool_use_id":null,"session_id":"c21284d0-1335-40fe-b082-4c454cb20fd4","uuid":"d4a6b04e-c748-4fd7-8a78-dbc638be30fc","timestamp":"2026-10-19T06:06:38.446Z","isSynthetic":true}"#
        guard case .messages(let messages, _, _) = parse(skill) else { Issue.record("Skill の本文の行を読めない"); return }
        #expect(messages.map(\.text) == ["Base directory for this skill: /Users/test/.claude/skills/commit\n\n# /commit"])
        #expect(messages.allSatisfy { $0.isInjected && $0.role == .user && $0.kind == .text })
        let interrupted = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"parent_tool_use_id":null,"uuid":"i1","isSynthetic":true}"#
        guard case .messages(let marks, _, _) = parse(interrupted) else { Issue.record("中断の行を読めない"); return }
        #expect(marks.map(\.kind) == [.notice] && marks.allSatisfy { !$0.isInjected })
    }

    @Test("can_use_tool の質問と権限の確認、hook_callback")
    func requests() {
        guard case .request(let ask) = parse(Fixture.askRequest), case .canUseTool(let question) = ask.kind else { Issue.record("質問を読めない"); return }
        #expect(ask.requestID == "ebe6a5d4-cf08-4940-982f-3af26a27b73d")
        #expect(question.toolName == "AskUserQuestion" && question.toolUseID == "toolu_016qGmhQdw34wo7qk4NqmdtW")
        #expect((object(question.inputJSON)["questions"] as? [[String: Any]])?.first?["question"] as? String == "Which color do you prefer?")

        guard case .request(let write) = parse(Fixture.writeRequest), case .canUseTool(let permission) = write.kind else { Issue.record("権限の確認を読めない"); return }
        #expect(permission.toolName == "Write" && permission.description == "agents-probe.txt")
        #expect(object(permission.inputJSON)["file_path"] as? String == "/tmp/work/agents-probe.txt")
        #expect(permission.suggestionsJSON?.contains("acceptEdits") == true)

        guard case .request(let hook) = parse(Fixture.hookCallback), case .hookCallback(let call) = hook.kind else { Issue.record("hook_callback を読めない"); return }
        #expect(call.callbackID == "cb_ups" && call.event == "UserPromptSubmit" && call.sessionID == "113e5da1-69af-4bb4-a7a8-7b9904379878")
        #expect(call.transcriptPath == "/Users/test/.claude/projects/-tmp-work/113e5da1-69af-4bb4-a7a8-7b9904379878.jsonl" && call.cwd == "/tmp/work")
        #expect(call.agentID == nil)

        let pre = #"{"type":"control_request","request_id":"r9","request":{"subtype":"hook_callback","callback_id":"cb_pre","input":{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"AskUserQuestion","tool_use_id":"toolu_q","tool_input":{"questions":[]}}}}"#
        guard case .request(let preRequest) = parse(pre), case .hookCallback(let preCall) = preRequest.kind else { Issue.record("PreToolUse を読めない"); return }
        #expect(preCall.toolName == "AskUserQuestion" && preCall.toolUseID == "toolu_q" && preCall.toolInputJSON == #"{"questions":[]}"#)

        #expect(parse(#"{"type":"control_request","request_id":"r1","request":{"subtype":"brand_new"}}"#) == .request(ClaudeControlRequest(requestID: "r1", kind: .other("brand_new"))))
        #expect(parse(#"{"type":"control_cancel_request","request_id":"r1"}"#) == .cancelRequest(requestID: "r1"))
    }

    @Test("result の時間・費用・送った発言の id。中断と defer")
    func results() {
        guard case .result(let done) = parse(Fixture.result) else { Issue.record("result を読めない"); return }
        #expect(done.subtype == "success" && !done.isError && done.stopReason == "end_turn" && done.text == "Blue")
        #expect(done.ttftMs == 1467 && done.durationMs == 4284 && done.outputTokens == 134 && done.costUSD == 0.00124213)
        #expect(done.userMessageIDs == ["4282c172-eb2c-49b6-890e-7e87b16335aa"] && done.deferred == nil)

        guard case .result(let aborted) = parse(Fixture.interrupted) else { Issue.record("中断の result を読めない"); return }
        #expect(aborted.subtype == "error_during_execution" && aborted.terminalReason == "aborted_streaming")

        let deferred = #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"tool_deferred","session_id":"s","deferred_tool_use":{"id":"toolu_q","name":"AskUserQuestion","input":{"questions":[{"question":"色は？"}]}}}"#
        guard case .result(let stopped) = parse(deferred) else { Issue.record("defer の result を読めない"); return }
        #expect(stopped.stopReason == "tool_deferred")
        #expect(stopped.deferred?.toolUseID == "toolu_q" && stopped.deferred?.name == "AskUserQuestion")
        #expect(((object(stopped.deferred?.inputJSON)["questions"] as? [[String: Any]])?.first?["question"] as? String) == "色は？")
    }

    @Test("利用枠は 0〜1 の utilization を % にする")
    func rateLimits() {
        guard case .rateLimits(let windows, let limit) = parse(Fixture.rateLimit) else { Issue.record("rate_limit_event を読めない"); return }
        #expect(limit == ClaudeRateLimit(rejected: false, resetsAt: Date(timeIntervalSince1970: 1_792_339_200)))
        #expect(windows["five_hour"]?.usedPercent == 17)
        #expect(windows["five_hour"]?.resetsAt == Date(timeIntervalSince1970: 1_792_339_200) && windows["five_hour"]?.windowSeconds == 18_000)
        #expect(windows["seven_day"] == nil)
    }

    @Test("上限で断られた窓は、unifiedWindows に無くても使い切った窓として読む（ほかの窓と、窓の種類の無い断りは足さない）")
    func rejectedRateLimit() {
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1792339200,"rateLimitType":"seven_day"},"session_id":"s1"}"#
        guard case .rateLimits(let windows, let limit) = parse(line) else { Issue.record("rate_limit_event を読めない"); return }
        #expect(limit == ClaudeRateLimit(rejected: true, resetsAt: Date(timeIntervalSince1970: 1_792_339_200)))
        #expect(windows["seven_day"] == UsageWindow(usedPercent: 100, resetsAt: Date(timeIntervalSince1970: 1_792_339_200), windowSeconds: 604_800))
        #expect(windows["five_hour"] == nil)
        let untyped = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1792339200},"session_id":"s1"}"#
        guard case .rateLimits(let none, _) = parse(untyped) else { Issue.record("rate_limit_event を読めない"); return }
        #expect(none.isEmpty)
    }

    @Test("制御要求への応答")
    func responses() {
        #expect(parse(Fixture.error) == .response(ClaudeControlResponse(requestID: "req_3c4c4dae3f", isSuccess: false, payloadJSON: nil, error: "Server not found: nonexistent")))
        guard case .response(let ack) = parse(Fixture.interruptAck) else { Issue.record("応答を読めない"); return }
        #expect(ack.isSuccess && ack.payloadJSON == #"{"still_queued":[]}"#)
        #expect(parse(#"{"type":"control_response","response":{"subtype":"success","request_id":"r2"}}"#) == .response(ClaudeControlResponse(requestID: "r2", isSuccess: true, payloadJSON: nil, error: nil)))
    }

    @Test("知らない種類は読み飛ばす印、JSON でない行は読めない印")
    func unknown() {
        #expect(parse(Fixture.hookStarted) == .other(type: "system", subtype: "hook_started"))
        #expect(parse(#"{"type":"brand_new_kind","subtype":"x"}"#) == .other(type: "brand_new_kind", subtype: "x"))
        #expect(parse(#"{"type":"system","subtype":"session_state_changed","state":"paused"}"#) == .other(type: "system", subtype: "session_state_changed"))
        #expect(parse("") == .unreadable)
        #expect(parse("not json") == .unreadable)
        #expect(parse(#"{"no_type":1}"#) == .unreadable)
    }
}

@Suite("Claude Code の stream-json の入力を書く")
struct ClaudeStreamInputTests {
    @Test("人の発言は文だけなら content を文字列に、画像があれば block の配列にする")
    func user() {
        let plain = ClaudeStreamInput.user(text: "こんにちは", uuid: "m1")
        #expect(plain.last == UInt8(ascii: "\n"))
        let line = object(plain)
        #expect(line["type"] as? String == "user" && line["uuid"] as? String == "m1" && line["parent_tool_use_id"] is NSNull)
        #expect((line["message"] as? [String: Any])?["content"] as? String == "こんにちは")

        let withImage = object(ClaudeStreamInput.user(text: "これは？", images: [.init(mediaType: "image/png", base64: "iVBORw0KGgo=")], uuid: "m2"))
        let blocks = (withImage["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        #expect(blocks.map { $0["type"] as? String } == ["text", "image"])
        #expect((blocks.last?["source"] as? [String: Any])?["media_type"] as? String == "image/png")
    }

    @Test("制御要求と応答の行")
    func control() {
        let request = object(ClaudeStreamInput.request(id: "q1", subtype: "set_model", ["model": "sonnet"]))
        #expect(request["type"] as? String == "control_request" && request["request_id"] as? String == "q1")
        #expect((request["request"] as? [String: Any])?["subtype"] as? String == "set_model")
        #expect((request["request"] as? [String: Any])?["model"] as? String == "sonnet")

        let ok = object(ClaudeStreamInput.success(id: "r1", ["behavior": "allow"]))
        #expect((ok["response"] as? [String: Any])?["subtype"] as? String == "success")
        #expect(((ok["response"] as? [String: Any])?["response"] as? [String: Any])?["behavior"] as? String == "allow")

        let ng = object(ClaudeStreamInput.failure(id: "r2", "知らない要求"))
        #expect((ng["response"] as? [String: Any])?["error"] as? String == "知らない要求")
        // 書いた行は読む側でも同じ形に戻る
        #expect(ClaudeStreamParser.parse(ClaudeStreamInput.failure(id: "r2", "x")) == .response(ClaudeControlResponse(requestID: "r2", isSuccess: false, payloadJSON: nil, error: "x")))
    }

    @Test("initialize の応答の待っている問い、圧縮、keep_alive")
    func reinitialize() {
        guard case .response(let response) = parse(Fixture.reinitialize) else { Issue.record("応答でない"); return }
        #expect(response.isSuccess && response.requestID == "req_2a66fbd289")
        let pending = response.pendingRequests ?? []
        #expect(pending.count == 1 && pending.first?.requestID == "873d2db7")
        if case .canUseTool(let permission) = pending.first?.kind {
            #expect(permission.toolName == "Write" && permission.toolUseID == "toolu_w")
        } else {
            Issue.record("can_use_tool でない")
        }
        guard case .response(let plain) = parse(Fixture.interruptAck) else { Issue.record("応答でない"); return }
        #expect(plain.pendingRequests == nil, "initialize でない応答には無い")
        guard case .compacted(let divider) = parse(Fixture.compact) else { Issue.record("圧縮でない"); return }
        #expect(divider.text == "会話を圧縮しました" && divider.isCompactSummary, "前後のトークン数が揃わなければ数を出さない")
        #expect(parse(Fixture.keepAlive) == .other(type: "keep_alive", subtype: nil))
    }
}
