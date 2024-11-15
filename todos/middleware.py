import json
import logging
from django.http import HttpResponseForbidden
from prometheus_client import Counter, Histogram
from django.conf import settings
import time

logger = logging.getLogger('django.security')

# Prometheus metrics
admin_access_total = Counter(
    'django_admin_access_total',
    'Total number of admin page accesses',
    ['path', 'method', 'user_type']
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

# Add response time metrics
request_latency = Histogram(
    'django_request_latency_seconds',
    'Request latency in seconds',
    ['path', 'method']
)

class SecurityMonitoringMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        start_time = time.time()

        if request.path.startswith('/admin/'):
            user_type = 'authenticated' if request.user.is_authenticated else 'anonymous'
            admin_access_total.labels(
                path=request.path,
                method=request.method,
                user_type=user_type
            ).inc()

            logger.info(json.dumps({
                'event_type': 'security_event',
                'action': 'admin_access',
                'path': request.path,
                'method': request.method,
                'ip': self.get_client_ip(request),
                'user': str(request.user) if request.user.is_authenticated else 'anonymous'
            }))

            if request.path == '/admin/login/' and request.method == 'POST':
                if not request.user.is_authenticated:
                    failed_login_total.labels(
                        ip=self.get_client_ip(request)
                    ).inc()
                    
                    logger.warning(json.dumps({
                        'event_type': 'security_event',
                        'action': 'failed_login',
                        'ip': self.get_client_ip(request),
                        'path': request.path,
                        'username': request.POST.get('username', 'unknown')
                    }))

        response = self.get_response(request)
        
        # Record request duration
        request_latency.labels(
            path=request.path,
            method=request.method
        ).observe(time.time() - start_time)
        
        if 400 <= response.status_code < 600:
            http_errors_total.labels(
                status_code=str(response.status_code),
                path=request.path
            ).inc()
            
            logger.warning(json.dumps({
                'event_type': 'security_event',
                'action': 'http_error',
                'status_code': response.status_code,
                'path': request.path,
                'method': request.method,
                'ip': self.get_client_ip(request)
            }))

        return response

    def get_client_ip(self, request):
        x_forwarded_for = request.META.get('HTTP_X_FORWARDED_FOR')
        if x_forwarded_for:
            return x_forwarded_for.split(',')[0]
        return request.META.get('REMOTE_ADDR')