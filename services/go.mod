module github.com/example/meeting-bot-platform/services

go 1.24.0

require (
	github.com/aws/aws-sdk-go-v2 v1.36.3
	github.com/aws/aws-sdk-go-v2/config v1.29.14
	github.com/aws/aws-sdk-go-v2/credentials v1.17.57
	github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue v1.18.10
	github.com/aws/aws-sdk-go-v2/service/dynamodb v1.39.4
	github.com/aws/aws-sdk-go-v2/service/s3 v1.78.2
	github.com/aws/aws-sdk-go-v2/service/sqs v1.37.5
	github.com/aws/aws-sdk-go-v2/service/sts v1.33.15
	github.com/aws/smithy-go v1.22.2
	go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.59.0
	go.opentelemetry.io/otel v1.34.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp v1.34.0
	go.opentelemetry.io/otel/sdk v1.34.0
	go.opentelemetry.io/otel/trace v1.34.0
)
