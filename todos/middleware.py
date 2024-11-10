# django_app/myproject/middleware.py
import json
import logging
from django.http import HttpResponseForbidden

logger = logging.getLogger('django.security')

class SecurityMonitoringMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        # Log security-relevant requests
        if request.path.startswith('/admin/'):
            logger.info(json.dumps({
                'event_type': 'security_event',
                'action': 'admin_access',
                'path': request.path,
                'method': request.method,
                'ip': self.get_client_ip(request),
                'user': str(request.user) if request.user.is_authenticated else 'anonymous'
            }))

            # Log failed login attempts
            if request.path == '/admin/login/' and request.method == 'POST':
                if not request.user.is_authenticated:
                    logger.warning(json.dumps({
                        'event_type': 'security_event',
                        'action': 'failed_login',
                        'ip': self.get_client_ip(request),
                        'path': request.path
                    }))

        response = self.get_response(request)
        
        # Log HTTP 4xx and 5xx responses
        if 400 <= response.status_code < 600:
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