{{/*
Determines whether TLS should be enabled.
Returns "true" or "false" (string).
When tls.enabled is explicitly set, its value is used.
When tls.enabled is unset (null/invalid), falls back to .Values.external.
*/}}
{{- define "qdrant.tls.enabled" -}}
{{- $tls := .Values.tls | default dict -}}
{{- if kindIs "invalid" $tls.enabled -}}
{{- .Values.external | default false -}}
{{- else -}}
{{- $tls.enabled -}}
{{- end -}}
{{- end -}}
