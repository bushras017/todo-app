import base64
import json
import os
from typing import Dict, Any
from google.cloud import compute_v1, bigquery, logging
from datetime import datetime

class AlertHandler:
    def __init__(self):
        self.project_id = os.getenv('PROJECT_ID')
        self.compute_client = compute_v1.FirewallsClient()
        self.bigquery_client = bigquery.Client()
        self.logging_client = logging.Client()
        self.logger = self.logging_client.logger('alert-handler')

    def handle_alert(self, alert_data: Dict[str, Any]) -> None:
        """Main alert handling logic"""
        alert_name = alert_data['labels'].get('alertname')
        severity = alert_data['labels'].get('severity', 'warning')
        instance = alert_data['labels'].get('instance', 'unknown')

        # Log to Cloud Logging
        self.logger.log_struct({
            'alert_name': alert_name,
            'severity': severity,
            'instance': instance,
            'description': alert_data.get('annotations', {}).get('description'),
            'timestamp': datetime.utcnow().isoformat()
        }, severity=severity)

        # Store in BigQuery
        self.store_alert_bigquery(alert_data)

        # Handle specific alerts
        if alert_name == 'HighCPUUsage':
            self.handle_high_cpu(alert_data)
        elif alert_name == 'DiskSpaceLow':
            self.handle_disk_space(alert_data)
        elif alert_name == 'HighFailedLogins':
            self.handle_failed_logins(alert_data)

    def store_alert_bigquery(self, alert_data: Dict[str, Any]) -> None:
        """Store alert in BigQuery"""
        table_id = f"{self.project_id}.security_logs.alerts"
        rows_to_insert = [{
            'alert_name': alert_data['labels'].get('alertname'),
            'severity': alert_data['labels'].get('severity'),
            'instance': alert_data['labels'].get('instance'),
            'description': alert_data.get('annotations', {}).get('description'),
            'timestamp': datetime.utcnow().isoformat()
        }]
        
        errors = self.bigquery_client.insert_rows_json(table_id, rows_to_insert)
        if errors:
            self.logger.log_text(f"BigQuery insertion errors: {errors}", severity='ERROR')

    def handle_high_cpu(self, alert_data: Dict[str, Any]) -> None:
        """Handle high CPU usage alerts"""
        instance = alert_data['labels'].get('instance')
        value = float(alert_data.get('value', 0))
        
        self.logger.log_struct({
            'type': 'high_cpu',
            'instance': instance,
            'cpu_usage': value,
            'action': 'monitoring'
        }, severity='WARNING')

    def handle_disk_space(self, alert_data: Dict[str, Any]) -> None:
        """Handle low disk space alerts"""
        instance = alert_data['labels'].get('instance')
        value = float(alert_data.get('value', 0))
        
        self.logger.log_struct({
            'type': 'disk_space_low',
            'instance': instance,
            'disk_usage': value,
            'action': 'cleanup_initiated'
        }, severity='WARNING')

    def handle_failed_logins(self, alert_data: Dict[str, Any]) -> None:
        """Handle failed login alerts"""
        instance = alert_data['labels'].get('instance')
        ip_address = alert_data['labels'].get('source_ip')
        
        if ip_address:
            self.update_firewall_rules(ip_address)
            
        self.logger.log_struct({
            'type': 'failed_logins',
            'instance': instance,
            'ip_address': ip_address,
            'action': 'blocked_ip'
        }, severity='WARNING')

    def update_firewall_rules(self, ip_to_block: str) -> None:
        """Update firewall rules to block IP"""
        try:
            firewall = self.compute_client.get(
                project=self.project_id,
                firewall='blocked-ips'
            )
            
            # Add IP to blocked list
            current_ranges = set(firewall.source_ranges)
            current_ranges.add(f"{ip_to_block}/32")
            
            # Convert firewall to dict for update
            firewall_dict = {
                'name': firewall.name,
                'sourceRanges': list(current_ranges),
                'denied': [{'IPProtocol': 'all'}],
                'direction': firewall.direction,
                'priority': firewall.priority,
                'targetTags': firewall.target_tags
            }
            
            operation = self.compute_client.patch(
                project=self.project_id,
                firewall='blocked-ips',
                firewall_resource=firewall_dict
            )
            
            self.logger.log_text(f"Blocked IP address: {ip_to_block}")
        except Exception as e:
            self.logger.log_text(f"Error updating firewall rules: {e}", severity='ERROR')

def alert_handler(event, context):
    """Cloud Function entry point"""
    try:
        handler = AlertHandler()
        pubsub_message = base64.b64decode(event['data']).decode('utf-8')
        alert_data = json.loads(pubsub_message)
        handler.handle_alert(alert_data)
    except Exception as e:
        print(f"Error processing alert: {e}")
        raise