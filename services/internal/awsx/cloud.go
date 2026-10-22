package awsx

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials/stscreds"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	dbtypes "github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/example/meeting-bot-platform/services/internal/domain"
	"github.com/example/meeting-bot-platform/services/internal/telemetry"
)

type Cloud struct {
	DDB *dynamodb.Client
	SQS *sqs.Client
	S3  *s3.Client
	STS *sts.Client
	Cfg aws.Config
}

func New(ctx context.Context) (*Cloud, error) {
	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, err
	}
	return &Cloud{DDB: dynamodb.NewFromConfig(cfg), SQS: sqs.NewFromConfig(cfg), S3: s3.NewFromConfig(cfg), STS: sts.NewFromConfig(cfg), Cfg: cfg}, nil
}

func tableName() string      { return os.Getenv("JOBS_TABLE") }
func requestQueue() string   { return os.Getenv("REQUEST_QUEUE_URL") }
func deliveryQueue() string  { return os.Getenv("DELIVERY_QUEUE_URL") }
func artifactBucket() string { return os.Getenv("ARTIFACT_BUCKET") }

func (c *Cloud) CreateJob(ctx context.Context, req domain.CreateRequest, idempotencyKey string) (domain.Job, bool, error) {
	if tableName() == "" || requestQueue() == "" {
		return domain.Job{}, false, errors.New("JOBS_TABLE and REQUEST_QUEUE_URL must be configured")
	}
	key := strings.TrimSpace(idempotencyKey)
	if key == "" {
		key = randomID()
	}
	keyHash := sha256.Sum256([]byte(key))
	requestHash := sha256.Sum256([]byte(req.MeetingURL + "\x00" + fmt.Sprint(req.DurationSeconds)))
	idemPK := "IDEMP#" + hex.EncodeToString(keyHash[:])
	job := domain.Job{ID: randomID(), Status: domain.Requested, MeetingURL: req.MeetingURL, DurationSeconds: req.DurationSeconds, CreatedAt: time.Now().UTC(), UpdatedAt: time.Now().UTC()}
	jobItem, err := attributevalue.MarshalMap(job)
	if err != nil {
		return domain.Job{}, false, err
	}
	jobItem["PK"] = &dbtypes.AttributeValueMemberS{Value: "JOB#" + job.ID}
	jobItem["SK"] = &dbtypes.AttributeValueMemberS{Value: "META"}
	jobItem["entity"] = &dbtypes.AttributeValueMemberS{Value: "JOB"}
	idemItem := map[string]dbtypes.AttributeValue{
		"PK": &dbtypes.AttributeValueMemberS{Value: idemPK}, "SK": &dbtypes.AttributeValueMemberS{Value: "META"},
		"jobId": &dbtypes.AttributeValueMemberS{Value: job.ID}, "requestHash": &dbtypes.AttributeValueMemberS{Value: hex.EncodeToString(requestHash[:])}, "expiresAt": &dbtypes.AttributeValueMemberN{Value: fmt.Sprint(time.Now().Add(24 * time.Hour).Unix())},
	}
	event := domain.Event{Kind: "START", JobID: job.ID, DurationSeconds: job.DurationSeconds, TraceContext: telemetry.InjectTrace(ctx)}
	eventJSON, err := json.Marshal(event)
	if err != nil {
		return domain.Job{}, false, err
	}
	outbox := map[string]dbtypes.AttributeValue{
		"PK": &dbtypes.AttributeValueMemberS{Value: "OUTBOX#" + job.ID}, "SK": &dbtypes.AttributeValueMemberS{Value: "EVENT"},
		"entity": &dbtypes.AttributeValueMemberS{Value: "OUTBOX"}, "status": &dbtypes.AttributeValueMemberS{Value: "PENDING"},
		"body": &dbtypes.AttributeValueMemberS{Value: string(eventJSON)}, "GSI1PK": &dbtypes.AttributeValueMemberS{Value: "OUTBOX#PENDING"},
		"GSI1SK": &dbtypes.AttributeValueMemberS{Value: job.CreatedAt.Format(time.RFC3339Nano)},
	}
	_, err = c.DDB.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{TransactItems: []dbtypes.TransactWriteItem{
		{Put: &dbtypes.Put{TableName: aws.String(tableName()), Item: jobItem, ConditionExpression: aws.String("attribute_not_exists(PK)")}},
		{Put: &dbtypes.Put{TableName: aws.String(tableName()), Item: idemItem, ConditionExpression: aws.String("attribute_not_exists(PK)")}},
		{Put: &dbtypes.Put{TableName: aws.String(tableName()), Item: outbox, ConditionExpression: aws.String("attribute_not_exists(PK)")}},
	}})
	if err == nil {
		return job, false, nil
	}
	// A conditional conflict may be a retry with an existing idempotency key.
	got, getErr := c.DDB.GetItem(ctx, &dynamodb.GetItemInput{TableName: aws.String(tableName()), Key: map[string]dbtypes.AttributeValue{"PK": &dbtypes.AttributeValueMemberS{Value: idemPK}, "SK": &dbtypes.AttributeValueMemberS{Value: "META"}}, ConsistentRead: aws.Bool(true)})
	if getErr == nil && got.Item != nil {
		var existing struct {
			JobID       string `dynamodbav:"jobId"`
			RequestHash string `dynamodbav:"requestHash"`
		}
		if attributevalue.UnmarshalMap(got.Item, &existing) == nil {
			if existing.RequestHash != hex.EncodeToString(requestHash[:]) {
				return domain.Job{}, false, domain.ErrIdempotencyConflict
			}
			oldJob, readErr := c.GetJob(ctx, existing.JobID)
			if readErr == nil {
				return oldJob, true, nil
			}
		}
	}
	return domain.Job{}, false, fmt.Errorf("create transaction failed: %w", err)
}

func (c *Cloud) GetJob(ctx context.Context, id string) (domain.Job, error) {
	out, err := c.DDB.GetItem(ctx, &dynamodb.GetItemInput{TableName: aws.String(tableName()), Key: map[string]dbtypes.AttributeValue{"PK": &dbtypes.AttributeValueMemberS{Value: "JOB#" + id}, "SK": &dbtypes.AttributeValueMemberS{Value: "META"}}, ConsistentRead: aws.Bool(true)})
	if err != nil {
		return domain.Job{}, err
	}
	if len(out.Item) == 0 {
		return domain.Job{}, errors.New("job not found")
	}
	var job domain.Job
	if err := attributevalue.UnmarshalMap(out.Item, &job); err != nil {
		return domain.Job{}, err
	}
	return job, nil
}

func (c *Cloud) GetArtifactURL(ctx context.Context, id string) (string, error) {
	job, err := c.GetJob(ctx, id)
	if err != nil {
		return "", err
	}
	if job.Status != domain.Completed || job.ArtifactKey == "" {
		return "", domain.ErrArtifactNotReady
	}
	presigner := s3.NewPresignClient(c.S3)
	presigned, err := presigner.PresignGetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(artifactBucket()),
		Key:    aws.String(job.ArtifactKey),
	}, func(options *s3.PresignOptions) {
		options.Expires = 15 * time.Minute
	})
	if err != nil {
		return "", err
	}
	return presigned.URL, nil
}

func (c *Cloud) UpdateStatus(ctx context.Context, id, status, message string) error {
	allowed := map[string][]string{
		domain.Starting:  {domain.Requested, domain.Queued},
		domain.Queued:    {domain.Starting},
		domain.Joining:   {domain.Starting},
		domain.Recording: {domain.Joining},
		domain.Uploading: {domain.Recording},
		domain.Completed: {domain.Uploading},
		domain.Failed:    {domain.Requested, domain.Queued, domain.Starting, domain.Joining, domain.Recording, domain.Uploading},
		domain.Cancelled: {domain.CancelRequested},
	}
	previous := allowed[status]
	if len(previous) == 0 {
		return fmt.Errorf("unsupported job state transition to %s", status)
	}
	previous = append(previous, status)
	names := map[string]string{"#status": "status", "#error": "error"}
	values := map[string]dbtypes.AttributeValue{":status": &dbtypes.AttributeValueMemberS{Value: status}, ":updatedAt": &dbtypes.AttributeValueMemberS{Value: time.Now().UTC().Format(time.RFC3339Nano)}, ":error": &dbtypes.AttributeValueMemberS{Value: message}}
	placeholders := make([]string, 0, len(previous))
	for i, state := range previous {
		placeholder := fmt.Sprintf(":previous%d", i)
		placeholders = append(placeholders, placeholder)
		values[placeholder] = &dbtypes.AttributeValueMemberS{Value: state}
	}
	_, err := c.DDB.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName:                 aws.String(tableName()),
		Key:                       map[string]dbtypes.AttributeValue{"PK": &dbtypes.AttributeValueMemberS{Value: "JOB#" + id}, "SK": &dbtypes.AttributeValueMemberS{Value: "META"}},
		UpdateExpression:          aws.String("SET #status = :status, updatedAt = :updatedAt, #error = :error"),
		ExpressionAttributeNames:  names,
		ExpressionAttributeValues: values,
		ConditionExpression:       aws.String("#status IN (" + strings.Join(placeholders, ", ") + ")"),
	})
	return err
}

func (c *Cloud) SetArtifactKey(ctx context.Context, id, key string) error {
	_, err := c.DDB.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName:                 aws.String(tableName()),
		Key:                       map[string]dbtypes.AttributeValue{"PK": &dbtypes.AttributeValueMemberS{Value: "JOB#" + id}, "SK": &dbtypes.AttributeValueMemberS{Value: "META"}},
		UpdateExpression:          aws.String("SET artifactKey = :key, updatedAt = :updatedAt"),
		ExpressionAttributeValues: map[string]dbtypes.AttributeValue{":key": &dbtypes.AttributeValueMemberS{Value: key}, ":updatedAt": &dbtypes.AttributeValueMemberS{Value: time.Now().UTC().Format(time.RFC3339Nano)}},
		ConditionExpression:       aws.String("attribute_exists(PK)"),
	})
	return err
}

func (c *Cloud) SetDeliveryStatus(ctx context.Context, id, status, message string) error {
	_, err := c.DDB.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName:                 aws.String(tableName()),
		Key:                       map[string]dbtypes.AttributeValue{"PK": &dbtypes.AttributeValueMemberS{Value: "JOB#" + id}, "SK": &dbtypes.AttributeValueMemberS{Value: "META"}},
		UpdateExpression:          aws.String("SET deliveryStatus = :status, deliveryMessage = :message, updatedAt = :updatedAt"),
		ExpressionAttributeValues: map[string]dbtypes.AttributeValue{":status": &dbtypes.AttributeValueMemberS{Value: status}, ":message": &dbtypes.AttributeValueMemberS{Value: message}, ":updatedAt": &dbtypes.AttributeValueMemberS{Value: time.Now().UTC().Format(time.RFC3339Nano)}},
		ConditionExpression:       aws.String("attribute_exists(PK)"),
	})
	return err
}

func (c *Cloud) CancelJob(ctx context.Context, id string) (domain.Job, error) {
	job, err := c.GetJob(ctx, id)
	if err != nil {
		return domain.Job{}, err
	}
	if domain.IsTerminal(job.Status) || job.Status == domain.CancelRequested {
		return job, nil
	}
	event, _ := json.Marshal(domain.Event{Kind: "CANCEL", JobID: id})
	_, err = c.DDB.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{TransactItems: []dbtypes.TransactWriteItem{
		{Update: &dbtypes.Update{
			TableName:                 aws.String(tableName()),
			Key:                       map[string]dbtypes.AttributeValue{"PK": &dbtypes.AttributeValueMemberS{Value: "JOB#" + id}, "SK": &dbtypes.AttributeValueMemberS{Value: "META"}},
			UpdateExpression:          aws.String("SET #status = :status, cancelRequested = :yes, updatedAt = :updatedAt"),
			ConditionExpression:       aws.String("#status <> :completed AND #status <> :failed AND #status <> :cancelled AND #status <> :cancelRequested"),
			ExpressionAttributeNames:  map[string]string{"#status": "status"},
			ExpressionAttributeValues: map[string]dbtypes.AttributeValue{":status": &dbtypes.AttributeValueMemberS{Value: domain.CancelRequested}, ":yes": &dbtypes.AttributeValueMemberBOOL{Value: true}, ":updatedAt": &dbtypes.AttributeValueMemberS{Value: time.Now().UTC().Format(time.RFC3339Nano)}, ":completed": &dbtypes.AttributeValueMemberS{Value: domain.Completed}, ":failed": &dbtypes.AttributeValueMemberS{Value: domain.Failed}, ":cancelled": &dbtypes.AttributeValueMemberS{Value: domain.Cancelled}, ":cancelRequested": &dbtypes.AttributeValueMemberS{Value: domain.CancelRequested}},
		}},
		{Put: &dbtypes.Put{TableName: aws.String(tableName()), Item: map[string]dbtypes.AttributeValue{
			"PK": &dbtypes.AttributeValueMemberS{Value: "OUTBOX#CANCEL#" + id}, "SK": &dbtypes.AttributeValueMemberS{Value: "EVENT"}, "entity": &dbtypes.AttributeValueMemberS{Value: "OUTBOX"}, "status": &dbtypes.AttributeValueMemberS{Value: "PENDING"},
			"body": &dbtypes.AttributeValueMemberS{Value: string(event)}, "GSI1PK": &dbtypes.AttributeValueMemberS{Value: "OUTBOX#PENDING"}, "GSI1SK": &dbtypes.AttributeValueMemberS{Value: time.Now().UTC().Format(time.RFC3339Nano)},
		}, ConditionExpression: aws.String("attribute_not_exists(PK)")}},
	}})
	if err != nil {
		current, readErr := c.GetJob(ctx, id)
		if readErr == nil && (current.Status == domain.CancelRequested || domain.IsTerminal(current.Status)) {
			return current, nil
		}
		return domain.Job{}, err
	}
	job.Status, job.CancelRequested, job.UpdatedAt = domain.CancelRequested, true, time.Now().UTC()
	return job, nil
}

func (c *Cloud) DispatchOutbox(ctx context.Context) error {
	page, err := c.DDB.Query(ctx, &dynamodb.QueryInput{TableName: aws.String(tableName()), IndexName: aws.String("GSI1"), KeyConditionExpression: aws.String("GSI1PK = :pending"), ExpressionAttributeValues: map[string]dbtypes.AttributeValue{":pending": &dbtypes.AttributeValueMemberS{Value: "OUTBOX#PENDING"}}, Limit: aws.Int32(10)})
	if err != nil {
		return err
	}
	for _, item := range page.Items {
		var row struct {
			PK   string `dynamodbav:"PK"`
			SK   string `dynamodbav:"SK"`
			Body string `dynamodbav:"body"`
		}
		if err := attributevalue.UnmarshalMap(item, &row); err != nil {
			continue
		}
		if _, err := c.SQS.SendMessage(ctx, &sqs.SendMessageInput{QueueUrl: aws.String(requestQueue()), MessageBody: aws.String(row.Body)}); err != nil {
			return err
		}
		_, err = c.DDB.UpdateItem(ctx, &dynamodb.UpdateItemInput{TableName: aws.String(tableName()), Key: map[string]dbtypes.AttributeValue{"PK": &dbtypes.AttributeValueMemberS{Value: row.PK}, "SK": &dbtypes.AttributeValueMemberS{Value: row.SK}}, UpdateExpression: aws.String("SET #status = :sent REMOVE GSI1PK, GSI1SK"), ConditionExpression: aws.String("#status = :pending"), ExpressionAttributeNames: map[string]string{"#status": "status"}, ExpressionAttributeValues: map[string]dbtypes.AttributeValue{":sent": &dbtypes.AttributeValueMemberS{Value: "SENT"}, ":pending": &dbtypes.AttributeValueMemberS{Value: "PENDING"}}})
		if err != nil {
			return err
		}
	}
	return nil
}

func (c *Cloud) Receive(ctx context.Context, queueURL string) ([]Message, error) {
	out, err := c.SQS.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{QueueUrl: aws.String(queueURL), MaxNumberOfMessages: 5, WaitTimeSeconds: 20, VisibilityTimeout: 300})
	if err != nil {
		return nil, err
	}
	messages := make([]Message, 0, len(out.Messages))
	for _, msg := range out.Messages {
		messages = append(messages, Message{Body: aws.ToString(msg.Body), Receipt: aws.ToString(msg.ReceiptHandle)})
	}
	return messages, nil
}

type Message struct {
	Body    string
	Receipt string
}

func (c *Cloud) DeleteMessage(ctx context.Context, queueURL, receipt string) error {
	_, err := c.SQS.DeleteMessage(ctx, &sqs.DeleteMessageInput{QueueUrl: aws.String(queueURL), ReceiptHandle: aws.String(receipt)})
	return err
}

func (c *Cloud) UploadArtifact(ctx context.Context, jobID, body string) (string, error) {
	key := "artifacts/" + jobID + "/artifact.txt"
	checksum := sha256.Sum256([]byte(body))
	_, err := c.S3.PutObject(ctx, &s3.PutObjectInput{Bucket: aws.String(artifactBucket()), Key: aws.String(key), Body: strings.NewReader(body), ContentType: aws.String("text/plain; charset=utf-8"), ChecksumSHA256: aws.String(base64.StdEncoding.EncodeToString(checksum[:])), Metadata: map[string]string{"job-id": jobID}})
	return key, err
}

func (c *Cloud) EnqueueDelivery(ctx context.Context, jobID, key string) error {
	if deliveryQueue() == "" {
		return nil
	}
	body, err := json.Marshal(domain.DeliveryEvent{JobID: jobID, ArtifactKey: key, TraceContext: telemetry.InjectTrace(ctx)})
	if err != nil {
		return err
	}
	_, err = c.SQS.SendMessage(ctx, &sqs.SendMessageInput{QueueUrl: aws.String(deliveryQueue()), MessageBody: aws.String(string(body))})
	return err
}

func (c *Cloud) CopyArtifact(ctx context.Context, key, destinationBucket, destinationRole, expectedOwner string) error {
	if destinationBucket == "" {
		return nil
	}
	if destinationRole == "" {
		return errors.New("DESTINATION_ROLE_ARN is required when DELIVERY_BUCKET is set")
	}
	provider := stscreds.NewAssumeRoleProvider(c.STS, destinationRole, func(o *stscreds.AssumeRoleOptions) { o.RoleSessionName = "meeting-bot-delivery" })
	cfg := c.Cfg
	cfg.Credentials = aws.NewCredentialsCache(provider)
	client := s3.NewFromConfig(cfg)
	_, err := client.CopyObject(ctx, &s3.CopyObjectInput{
		Bucket: aws.String(destinationBucket), Key: aws.String("meeting-bot/" + strings.TrimPrefix(key, "artifacts/")),
		CopySource:          aws.String(url.PathEscape(artifactBucket() + "/" + key)),
		ExpectedBucketOwner: optional(expectedOwner), ExpectedSourceBucketOwner: optional(os.Getenv("AWS_ACCOUNT_ID")),
		MetadataDirective: "COPY",
	})
	return err
}

func optional(v string) *string {
	if v == "" {
		return nil
	}
	return aws.String(v)
}

func randomID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("crypto/rand unavailable: " + err.Error())
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func RequestQueueURL() string  { return requestQueue() }
func DeliveryQueueURL() string { return deliveryQueue() }
