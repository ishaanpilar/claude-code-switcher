-- Every table the Swift client subscribes to for live sync (BUILD_PLAN.md
-- section 3d: "subscribe, don't poll, for coordination state"). usage_history
-- and turn_log/switch_log are deliberately excluded — those are read on
-- demand for the attribution view, not watched live.

alter publication supabase_realtime add table accounts;
alter publication supabase_realtime add table account_tokens;
alter publication supabase_realtime add table usage_current;
alter publication supabase_realtime add table claims;
alter publication supabase_realtime add table poll_leader;
