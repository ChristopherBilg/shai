# Re-Review Package — Task 1 Fix Round 1

## Fix Diff (a1030f1..f7cdee0)

```diff
diff --git a/shai-dispatch b/shai-dispatch
index 0d9a7f0..a345408 100755
--- a/shai-dispatch
+++ b/shai-dispatch
@@ -36,9 +36,11 @@ check_policy() {
         ))
       )
     | .action
-  ' "$policy_file" 2>/dev/null | head -n 1)
+  ' "$policy_file" 2>/dev/null | head -n 1) || action=""
 
-  printf '%s' "${action:-$(jq -r '.default // "prompt"' "$policy_file" 2>/dev/null || printf 'prompt')}"
+  local fallback
+  fallback=$(jq -r '.default // "prompt"' "$policy_file" 2>/dev/null) || fallback=""
+  printf '%s' "${action:-${fallback:-prompt}}"
 }
 
 run_tool() {
```
