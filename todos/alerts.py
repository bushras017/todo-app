# todos/alerts.py
from google.cloud import pubsub_v1, bigquery
import json
import os
from datetime import datetime
import logging
from dataclasses import dataclass, asdict
from typing import Optional
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from prometheus_client import Counter, Histogram, Gauge

logger = logging.getLogger('django.security')

# Prometheus metrics
admin_access_total = Counter(
    'django_admin_access_total',
    'Total number of admin page accesses',
    ['path', 'method', 'user_type']
)

failed_login_rate = Gauge(
    'django_failed_login_rate',
    'Rate of failed login attempts',
    ['ip']
)

failed_login_total = Counter(
    'django_failed_login_total',
    'Total number of failed login attempts',
    ['ip']
)

http_errors_total = Counter(
    'django_http_errors_total',
    'Total number of HTTP 4xx and 5xx errors',
    ['status_code', 'path']
)

request_latency = Histogram(
    'django_request_latency_seconds',
    'Request latency in seconds',
    ['path', 'method']
)

@dataclass
class SecurityAlert:
    alert_name: str
    severity: str
    instance: str
    description: str
    source_ip: Optional[str] = None
    user: Optional[str] = None
    timestamp: Optional[str] = None
    metrics: Optional[dict] = None

    def __post_init__(self):
        if not self.timestamp:
            self.timestamp = datetime.utcnow().isoformat()

    def to_dict(self):
        data = {k: v for k, v in asdict(self).items() if v is not None}
        if self.metrics:
            data.update(self.metrics)
        return data

class AlertManager:
    def __init__(self):
        self.project_id = os.getenv('GOOGLE_CLOUD_PROJECT')
        # Initialize Pub/Sub client only if project ID is available
        if self.project_id:
            try:
                self.publisher = pubsub_v1.PublisherClient()
                self.topic_path = self.publisher.topic_path(self.project_id, 'prometheus-alerts')
            except Exception as e:
                logger.error(f"Failed to initialize Pub/Sub client: {str(e)}")
                self.publisher = None
                self.topic_path = None

        # Email settings
        self.smtp_server = "smtp.gmail.com"
        self.smtp_port = 587
        self.sender_email = os.getenv('NOTIFICATION_EMAIL')
        self.email_password = os.getenv('EMAIL_APP_PASSWORD')
        self.recipient_emails = json.loads(os.getenv('ALERT_EMAIL_RECIPIENTS', ''))
        self.recipient_emails = [email.strip() for email in self.recipient_emails]
        # Initialize BigQuery client only if project ID is available
        if self.project_id:
            try:
                self.bigquery_client = bigquery.Client()
                self.table_id = f"{self.project_id}.security_logs.alerts"
            except Exception as e:
                logger.error(f"Failed to initialize BigQuery client: {str(e)}")
                self.bigquery_client = None
                self.table_id = None

    def publish_alert(self, alert: SecurityAlert):
        """Publish alert to all configured channels"""
        try:
            # Convert alert to JSON
            alert_data = alert.to_dict()
            
            # Always log the alert
            self._log_alert(alert_data)
            
            # Publish to Pub/Sub if available
            if self.publisher and self.topic_path:
                self._publish_to_pubsub(alert_data)
            
            # Store in BigQuery if available
            if self.bigquery_client and self.table_id:
                self._store_in_bigquery(alert_data)
            
            # Send email for high-severity alerts
            if alert.severity.lower() in ['critical', 'high', 'error']:
                self._send_email_alert(alert)
                
        except Exception as e:
            logger.error(f"Failed to process alert: {str(e)}", exc_info=True)

    def _log_alert(self, alert_data: dict):
        """Log alert to Django logger"""
        severity = alert_data.get('severity', 'info').lower()
        log_method = getattr(logger, severity, logger.info)
        log_method(json.dumps({
            'event_type': 'security_alert',
            **alert_data
        }))

    def _publish_to_pubsub(self, alert_data: dict):
        """Publish alert to Pub/Sub"""
        try:
            data = json.dumps(alert_data).encode('utf-8')
            future = self.publisher.publish(self.topic_path, data)
            future.result()  # Wait for publishing to complete
            logger.info(f"Alert published to Pub/Sub: {alert_data['alert_name']}")
        except Exception as e:
            logger.error(f"Failed to publish to Pub/Sub: {str(e)}", exc_info=True)

    def _store_in_bigquery(self, alert_data: dict):
        """Store alert in BigQuery"""
        try:
            errors = self.bigquery_client.insert_rows_json(self.table_id, [alert_data])
            if errors:
                logger.error(f"BigQuery insertion errors: {errors}")
        except Exception as e:
            logger.error(f"Failed to store in BigQuery: {str(e)}", exc_info=True)

    def _send_email_alert(self, alert: SecurityAlert):
        """Send email notification for critical alerts"""
        try:
            if not all([self.sender_email, self.email_password, self.recipient_emails]):
                return

            msg = MIMEMultipart()
            msg['From'] = self.sender_email
            msg['To'] = ', '.join(self.recipient_emails)
            msg['Subject'] = f"[{alert.severity.upper()}] {alert.alert_name} on {alert.instance}"
            
            body = self._format_email_body(alert)
            msg.attach(MIMEText(body, 'plain'))
            
            with smtplib.SMTP(self.smtp_server, self.smtp_port) as server:
                server.starttls()
                server.login(self.sender_email, self.email_password)
                server.send_message(msg)
                
            logger.info(f"Alert email sent: {alert.alert_name}")
        except Exception as e:
            logger.error(f"Failed to send email: {str(e)}", exc_info=True)

    def _format_email_body(self, alert: SecurityAlert) -> str:
        """Format alert email body"""
        body = f"""
        Security Alert Details:
        ---------------------
        Name: {alert.alert_name}
        Severity: {alert.severity}
        Instance: {alert.instance}
        Description: {alert.description}
        Time: {alert.timestamp}
        """
        if alert.source_ip:
            body += f"Source IP: {alert.source_ip}\n"
        if alert.user:
            body += f"User: {alert.user}\n"
        if alert.metrics:
            body += "\nMetrics:\n"
            for key, value in alert.metrics.items():
                body += f"{key}: {value}\n"
        return body