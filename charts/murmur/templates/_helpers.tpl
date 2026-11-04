{{- define "murmur.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "murmur.labels" -}}
app.kubernetes.io/name: murmur
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "murmur.selector" -}}
app.kubernetes.io/name: murmur
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "murmur.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}
{{- end -}}

{{- define "murmur.natsUrl" -}}
{{- if .Values.natsUrl -}}
{{ .Values.natsUrl }}
{{- else -}}
{{- $name := ternary .Release.Name (printf "%s-nats" .Release.Name) (contains "nats" .Release.Name) -}}
nats://{{ $name }}:4222
{{- end -}}
{{- end -}}

{{/* env shared by the server and the worker */}}
{{- define "murmur.commonEnv" -}}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      {{- if .Values.database.cnpg.enabled }}
      name: {{ include "murmur.fullname" . }}-db-app
      key: uri
      {{- else }}
      name: {{ required "database.external.existingSecret is required without database.cnpg" .Values.database.external.existingSecret }}
      key: {{ .Values.database.external.key }}
      {{- end }}
- name: NATS_URL
  value: {{ include "murmur.natsUrl" . | quote }}
- name: TIMEZONE
  value: {{ .Values.timezone | quote }}
{{- end -}}
