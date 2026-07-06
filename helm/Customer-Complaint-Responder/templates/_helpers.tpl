{{/*
Expand the name of the chart.
*/}}
{{- define "Customer-Complaint-Responder.name" -}}
{{- default .Chart.Name .Values.nameOverride | lower | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "Customer-Complaint-Responder.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | lower | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | lower | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | lower | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "Customer-Complaint-Responder.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "Customer-Complaint-Responder.labels" -}}
helm.sh/chart: {{ include "Customer-Complaint-Responder.chart" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "Customer-Complaint-Responder.selectorLabels" -}}
app.kubernetes.io/name: {{ include "Customer-Complaint-Responder.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "Customer-Complaint-Responder.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "Customer-Complaint-Responder.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* ======================================================================
     Per-component labels
     ====================================================================== */}}

{{/*
Redis labels
*/}}
{{- define "Customer-Complaint-Responder.redis.labels" -}}
{{ include "Customer-Complaint-Responder.labels" . }}
{{ include "Customer-Complaint-Responder.redis.selectorLabels" . }}
app.kubernetes.io/component: redis
{{- end }}

{{/*
Redis selector labels
*/}}
{{- define "Customer-Complaint-Responder.redis.selectorLabels" -}}
app: redis
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Poller labels
*/}}
{{- define "Customer-Complaint-Responder.poller.labels" -}}
{{ include "Customer-Complaint-Responder.labels" . }}
{{ include "Customer-Complaint-Responder.poller.selectorLabels" . }}
app.kubernetes.io/component: poller
{{- end }}

{{/*
Poller selector labels
*/}}
{{- define "Customer-Complaint-Responder.poller.selectorLabels" -}}
app: poller
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Worker labels
*/}}
{{- define "Customer-Complaint-Responder.worker.labels" -}}
{{ include "Customer-Complaint-Responder.labels" . }}
{{ include "Customer-Complaint-Responder.worker.selectorLabels" . }}
app.kubernetes.io/component: worker
{{- end }}

{{/*
Worker selector labels
*/}}
{{- define "Customer-Complaint-Responder.worker.selectorLabels" -}}
app: worker
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Redis internal URL — constructs the in-cluster DNS name using the release namespace.
*/}}
{{- define "Customer-Complaint-Responder.redisUrl" -}}
redis://redis.{{ .Release.Namespace }}.svc.cluster.local:{{ .Values.redis.port }}/0
{{- end }}
