# Review Package — Task 1: Add check_policy to shai-dispatch

## Commits
```
a1030f1 Add check_policy to shai-dispatch (sandboxing task 1)
```

## Stat
```
 shai-dispatch | 33 +++++++++++++++++++++++++++++++++
 1 file changed, 33 insertions(+)
```

## Diff (a0093a1..a1030f1)

```diff
diff --git a/shai-dispatch b/shai-dispatch
index 7801f51..0d9a7f0 100755
--- a/shai-dispatch
+++ b/shai-dispatch
@@ -8,6 +8,39 @@ set -euo pipefail
 
 MAX_BYTES=8000
 
+STATE_DIR="${SHAI_HOME:-$HOME/.shai}"
+
+check_policy() {
+  local tool_name="$1" tool_input="$2"
+  local policy_file="$STATE_DIR/policy.json"
+
+  if [ ! -f "$policy_file" ]; then
+    case "$tool_name" in
+      print_file | list_directory | gh_pr_view | gh_issue_view) printf 'allow' ;;
+      *) printf 'prompt' ;;
+    esac
+    return 0
+  fi
+
+  local action
+  action=$(jq -r --arg name "$tool_name" --argjson input "$tool_input" '
+    .rules[]?
+    | select(.tool == $name)
+    | select(
+        (has("args") | not) or
+        (.args | to_entries | all(
+          .key as $k | .value as $v |
+          ($input[$k] // "") | test(
+            "^" + ($v | gsub("(?<c>[.+?^${}()|\\[\\]])"; "\\\(.c)";"x") | gsub("\\*"; ".*")) + "$"
+          )
+        ))
+      )
+    | .action
+  ' "$policy_file" 2>/dev/null | head -n 1)
+
+  printf '%s' "${action:-$(jq -r '.default // "prompt"' "$policy_file" 2>/dev/null || printf 'prompt')}"
+}
+
 run_tool() {
   local name="$1" input="$2" number repo path
   case "$name" in
```
