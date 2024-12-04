import json
import logging
from django.http import HttpResponseForbidden
import time
from todos.alerts import AlertManager, SecurityAlert, admin_access_total, failed_login_rate, \
failed_login_total, http_errors_total, request_latency

logger = logging.getLogger('django.security')
alert_manager = AlertManager()

class SecurityMonitoringMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response
        self.failed_login_window = {}  # Track failed logins within time window

    def __call__(self, request):
        start_time = time.time()
        response = None

        try:
            # Handle admin access monitoring
            if request.path.startswith('/admin/'):
                self._monitor_admin_access(request)

            # Get response
            response = self.get_response(request)
            
            # Record request duration
            request_latency.labels(
                path=request.path,
                method=request.method
            ).observe(time.time() - start_time)
            
            # Monitor error responses
            if response and 400 <= response.status_code < 600:
                self._monitor_error_response(request, response)

            return response

        except Exception as e:
            logger.error(f"Middleware error: {str(e)}", exc_info=True)
            if response:
                return response
            return self.get_response(request)

    def _monitor_admin_access(self, request):
        """Monitor and track admin interface access"""
        user_type = 'authenticated' if request.user.is_authenticated else 'anonymous'
        
        # Update Prometheus metrics
        admin_access_total.labels(
            path=request.path,
            method=request.method,
            user_type=user_type
        ).inc()

        # Create and publish alert
        alert = SecurityAlert(
            alert_name="AdminAccess",
            severity="info" if request.user.is_authenticated else "critical",
            instance=request.get_host(),
            description=f"Admin access on path: {request.path}",
            source_ip=self.get_client_ip(request),
            user=str(request.user) if request.user.is_authenticated else 'anonymous',
            metrics={
                'method': request.method,
                'path': request.path,
                'user_type': user_type
            }
        )
        alert_manager.publish_alert(alert)

        # Handle failed login attempts
        if request.path == '/admin/login/' and request.method == 'POST':
            if not request.user.is_authenticated:
                self._handle_failed_login(request)

    def _handle_failed_login(self, request):
        """Handle failed login attempts and increment Prometheus metrics"""
        ip = self.get_client_ip(request)
        username = request.POST.get('username', 'unknown')
        
        # First increment the counter and update rate metrics
        failed_login_total.labels(ip=ip).inc()
        self._track_failed_login(ip)
        
        # Calculate current rate for the alert
        current_time = time.time()
        window_size = 300  # 5 minutes
        attempts = len([t for t in self.failed_login_window.get(ip, []) 
                       if current_time - t < window_size])
        current_rate = attempts / (window_size / 60)  # per minute
        
        # Create and publish alert
        alert = SecurityAlert(
            alert_name="FailedLoginAttempt",
            severity="critical",  
            instance=request.get_host(),
            description=f"Failed login attempt for user: {username}",
            source_ip=ip,
            user=username,
            metrics={
                'failed_login_rate': current_rate
            }
        )
        alert_manager.publish_alert(alert)

    def _track_failed_login(self, ip):
        """Track failed login attempts and update metrics"""
        current_time = time.time()
        window_size = 300  # 5 minutes
        
        if ip not in self.failed_login_window:
            self.failed_login_window[ip] = []
        
        # Clean old entries
        self.failed_login_window[ip] = [
            t for t in self.failed_login_window[ip] 
            if current_time - t < window_size
        ]
        
        # Add current attempt
        self.failed_login_window[ip].append(current_time)
        
        # Update rate metric
        rate = len(self.failed_login_window[ip]) / (window_size / 60)  # per minute
        failed_login_rate.labels(ip=ip).set(rate)

    def _monitor_error_response(self, request, response):
        """Monitor and track error responses"""
        http_errors_total.labels(
            status_code=str(response.status_code),
            path=request.path
        ).inc()
        
        alert = SecurityAlert(
            alert_name="HTTPError",
            severity="error" if response.status_code >= 500 else "warning",
            instance=request.get_host(),
            description=f"HTTP {response.status_code} error on {request.path}",
            source_ip=self.get_client_ip(request),
            user=str(request.user) if request.user.is_authenticated else 'anonymous',
            metrics={
                'status_code': response.status_code,
                'method': request.method,
                'path': request.path
            }
        )
        alert_manager.publish_alert(alert)

    def get_client_ip(self, request):
        """Get client IP address from request"""
        x_forwarded_for = request.META.get('HTTP_X_FORWARDED_FOR')
        if x_forwarded_for:
            return x_forwarded_for.split(',')[0]
        return request.META.get('REMOTE_ADDR')