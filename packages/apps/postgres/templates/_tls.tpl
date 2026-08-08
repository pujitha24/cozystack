{{/*
postgres.tls.enabled resolves the tri-state tls.enabled field to a plain
string "true" or "false" so callers can use it with `eq`:

  {{- $tlsEnabled := (include "postgres.tls.enabled" .) | eq "true" -}}

Tri-state semantics:
  - tls.enabled explicitly set  → use that value
  - tls.enabled unset (null)    → auto-on when external is true
*/}}
{{- define "postgres.tls.enabled" -}}
{{- $tls := .Values.tls | default dict -}}
{{- if kindIs "invalid" $tls.enabled -}}
  {{- .Values.external | default false | toString -}}
{{- else -}}
  {{- $tls.enabled | toString -}}
{{- end -}}
{{- end -}}
