diff --git a/shai-dispatch b/shai-dispatch
index a345408..7a8f2c6 100755
--- a/shai-dispatch
+++ b/shai-dispatch
@@ -43,8 +43,41 @@ check_policy() {
   printf '%s' "${action:-${fallback:-prompt}}"
 }
 
+prompt_user() {
+  local tool_name="$1" tool_input="$2"
+  if ! [ -t 2 ]; then
+    return 1
+  fi
+  printf '\n⚠ shai wants to execute:\n' >/dev/tty
+  printf '  tool:  %s\n' "$tool_name" >/dev/tty
+  printf '%s' "$tool_input" | jq -r 'to_entries[] | "  \(.key):  \(.value)"' >/dev/tty 2>/dev/null
+  printf '\n  Allow? [y/N] ' >/dev/tty
+  local answer
+  read -r answer </dev/tty 2>/dev/null || answer=""
+  case "$answer" in
+    y | Y | yes | YES) return 0 ;;
+    *) return 1 ;;
+  esac
+}
+
 run_tool() {
-  local name="$1" input="$2" number repo path
+  local name="$1" input="$2"
+  local policy_action
+  policy_action=$(check_policy "$name" "$input")
+  case "$policy_action" in
+    allow) ;;
+    deny)
+      printf 'Policy denied: %s' "$name"
+      return 1
+      ;;
+    prompt)
+      if ! prompt_user "$name" "$input"; then
+        printf 'Permission denied: %s' "$name"
+        return 1
+      fi
+      ;;
+  esac
+  local number repo path
   case "$name" in
     gh_pr_view | gh_issue_view)
       number=$(printf '%s' "$input" | jq -r '.number')
diff --git a/tests/test_policy.sh b/tests/test_policy.sh
index f9ca8b3..07975a2 100755
--- a/tests/test_policy.sh
+++ b/tests/test_policy.sh
@@ -124,4 +124,36 @@ PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"other_tool","action":"al
 RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{}')
 assert_eq "$RES" "prompt" "no rule matches, no default field → prompt"
 
+# --- integration: the permission gate wired into run_tool, exercised through the full
+#     shai-dispatch pipeline (not the extracted functions) ---
+
+# deny produces is_error tool_result
+tmpdir=$(setup_policy '{"version":"1.0","default":"deny","rules":[{"tool":"list_directory","action":"deny"}]}')
+make_stub_bin
+stub_dir="$STUB"
+write_gh_stub
+event='{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"test_deny","name":"list_directory","input":{"path":"."}}],"stop_reason":"tool_use"}}'
+result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" PATH="$stub_dir:$PATH" bash "$DIR/shai-dispatch" 2>/dev/null) || true
+assert_contains "$result" '"is_error":true' "deny → is_error true"
+assert_contains "$result" 'Policy denied' "deny → error message"
+
+# non-interactive prompt → fail closed
+tmpdir=$(setup_policy '{"version":"1.0","default":"prompt","rules":[]}')
+make_stub_bin
+stub_dir="$STUB"
+write_gh_stub
+event='{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"test_prompt","name":"list_directory","input":{"path":"."}}],"stop_reason":"tool_use"}}'
+result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" PATH="$stub_dir:$PATH" bash "$DIR/shai-dispatch" 2>/dev/null) || true
+assert_contains "$result" '"is_error":true' "non-interactive prompt → is_error true"
+assert_contains "$result" 'Permission denied' "non-interactive prompt → denied message"
+
+# allow executes tool normally
+tmpdir=$(setup_policy '{"version":"1.0","default":"deny","rules":[{"tool":"list_directory","action":"allow"}]}')
+make_stub_bin
+stub_dir="$STUB"
+write_gh_stub
+event='{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"test_allow","name":"list_directory","input":{"path":"'"$tmpdir"'"}}],"stop_reason":"tool_use"}}'
+result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" PATH="$stub_dir:$PATH" bash "$DIR/shai-dispatch" 2>/dev/null) || true
+assert_contains "$result" '"is_error":false' "allow → executes, is_error false"
+
 finish
