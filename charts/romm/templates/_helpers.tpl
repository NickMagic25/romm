{{- define "romm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "romm.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- printf "%s" $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "romm.backend.fullname" -}}
{{- printf "%s-backend" (include "romm.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "romm.frontend.fullname" -}}
{{- printf "%s-frontend" (include "romm.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "romm.commonLabels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "romm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "romm.backend.labels" -}}
{{ include "romm.commonLabels" . }}
app.kubernetes.io/component: backend
{{- end -}}

{{- define "romm.frontend.labels" -}}
{{ include "romm.commonLabels" . }}
app.kubernetes.io/component: frontend
{{- end -}}

{{- define "romm.renderEnv" -}}
{{- range $key, $value := .Values.env }}
- name: {{ $key }}
  {{- if hasKey $.Values.secretEnv $key }}
  valueFrom:
    secretKeyRef:
      name: {{ (index $.Values.secretEnv $key).name | quote }}
      key: {{ (index $.Values.secretEnv $key).key | quote }}
  {{- else }}
  value: {{ $value | quote }}
  {{- end }}
{{- end }}
{{- end -}}
