pipeline {
    agent any

    environment {
        TARGET_SERVER = 'bushrask021@34.121.166.25'
        GIT_URL = 'https://github.com/bushras017/django-todo.git'
        DOCKER_IMAGE = 'sample_project'
        DJANGO_PORT = '8000'
        ZAP_FAILURE_THRESHOLD = '50'  // String to match environment variable handling
    }

    stages {
        stage('Deploy to Target Server') {
            steps {
                script {
                    sshagent(credentials: ['target-server']) {
                        sh '''
                            ssh -o StrictHostKeyChecking=no ${TARGET_SERVER} "
                                # Clone or update the repository
                                if [ -d \"django-todo\" ]; then
                                    cd django-todo
                                    git pull
                                else
                                    git clone ${GIT_URL} django-todo
                                    cd django-todo
                                fi

                                # Check if Docker is running
                                if ! sudo docker info > /dev/null 2>&1; then
                                    echo \"Docker is not running. Starting Docker...\"
                                    sudo systemctl start docker
                                fi

                                # Aggressively free up the port
                                echo \"Freeing up port ${DJANGO_PORT}...\"
                                
                                # Stop and remove any Docker containers using the port
                                sudo docker ps -q --filter publish=${DJANGO_PORT} | xargs -r sudo docker stop
                                sudo docker ps -aq --filter publish=${DJANGO_PORT} | xargs -r sudo docker rm
                                
                                # Kill any processes using the port
                                sudo lsof -ti:${DJANGO_PORT} | xargs -r sudo kill -9
                                
                                # Remove the specific container if it exists
                                sudo docker rm -f ${DOCKER_IMAGE} 2>/dev/null || true

                                # Build Docker image
                                sudo docker build -t ${DOCKER_IMAGE} .

                                # Run the Django application in a Docker container
                                sudo docker run -d -p ${DJANGO_PORT}:${DJANGO_PORT} --name ${DOCKER_IMAGE} ${DOCKER_IMAGE}

                                # Wait for Django to start
                                sleep 10
                                
                                # Verify the container is running
                                if ! sudo docker ps | grep -q ${DOCKER_IMAGE}; then
                                    echo \"Error: Container failed to start. Here are the logs:\"
                                    sudo docker logs ${DOCKER_IMAGE}
                                    exit 1
                                fi
                            "
                        '''
                    }
                }
            }
        }

        stage('Run DAST') {
            steps {
                script {
                    sshagent(credentials: ['target-server']) {
                        sh '''
                            ssh -o StrictHostKeyChecking=no ${TARGET_SERVER} "
                                cd django-todo

                                # Ensure the latest ZAP Docker image is pulled
                                sudo docker pull ghcr.io/zaproxy/zaproxy:stable

                                # Run OWASP ZAP scan using public IP
                                sudo docker run --rm -v \$(pwd):/zap/wrk/:rw ghcr.io/zaproxy/zaproxy:stable zap-baseline.py \\
                                    -t http://34.121.166.25:${DJANGO_PORT} \\
                                    -g gen.conf \\
                                    -r zap-report.html \\
                                    -J zap-report.json > /dev/null 2>&1 || true
                            "
                        '''
                    }
                }
            }
        }

        stage('Copy ZAP Reports') {
            steps {
                script {
                    sshagent(credentials: ['target-server']) {
                        sh '''
                            # SCP from target server back to Jenkins workspace
                            scp -o StrictHostKeyChecking=no ${TARGET_SERVER}:~/django-todo/zap-report.html ${WORKSPACE}/
                            scp -o StrictHostKeyChecking=no ${TARGET_SERVER}:~/django-todo/zap-report.json ${WORKSPACE}/
                        '''
                    }
                }
            }
        }

        stage('Analyze ZAP Results') {
            steps {
                script {
                    def zapResult = readJSON file: 'zap-report.json'
                    def highAlerts = 0
                    
                    // Safely parse the ZAP results
                    if (zapResult.site instanceof List && !zapResult.site.isEmpty()) {
                        def alerts = zapResult.site[0].alerts
                        if (alerts instanceof List) {
                            highAlerts = alerts.count { alert ->
                                def riskcode = alert.riskcode
                                if (riskcode instanceof String) {
                                    riskcode = riskcode.isInteger() ? riskcode.toInteger() : 0
                                } else if (riskcode instanceof Number) {
                                    riskcode = riskcode.intValue()
                                } else {
                                    riskcode = 0
                                }
                                return riskcode >= 3
                            }
                        }
                    }
                    
                    
                    echo "High Risk Alerts found: ${highAlerts}"
                    
                    // Convert both values to integers before comparison
                    if (highAlerts.toInteger() > ZAP_FAILURE_THRESHOLD.toInteger()) {
                        currentBuild.result = 'FAILURE'
                        error "DAST Testing failed: ${highAlerts} high risk vulnerabilities found (threshold: ${ZAP_FAILURE_THRESHOLD})"
                    } else {
                        echo "DAST Testing passed: ${highAlerts} high risk vulnerabilities found (threshold: ${ZAP_FAILURE_THRESHOLD})"
                    }
                }
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'zap-report.html,zap-report.json', fingerprint: true
            
            script {
                try {
                    publishHTML(target: [
                        allowMissing: false,
                        alwaysLinkToLastBuild: false,
                        keepAll: true,
                        reportDir: '.',
                        reportFiles: 'zap-report.html',
                        reportName: 'ZAP Security Report'
                    ])
                } catch (Exception e) {
                    echo "Warning: Unable to publish HTML report. The HTML Publisher plugin might not be installed."
                    echo "Exception: ${e.getMessage()}"
                    echo "The ZAP report is still available in the archived artifacts."
                }
            }
        }
    }
}
