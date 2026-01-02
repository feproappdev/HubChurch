###############################################################################
# Stage 1: Download and prepare ChurchCRM
###############################################################################
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    unzip \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp

# Download latest ChurchCRM release
RUN VERSION=$(curl -Is https://github.com/ChurchCRM/CRM/releases/latest | awk -F/ '/^location:/ {sub(/\r$/, "", $NF); print $NF}') && \
    echo "Downloading ChurchCRM version:  $VERSION" && \
    curl -L -o ChurchCRM. zip "https://github.com/ChurchCRM/CRM/releases/download/$VERSION/ChurchCRM-$VERSION.zip" && \
    unzip ChurchCRM.zip && \
    rm ChurchCRM.zip && \
    mv churchcrm /opt/churchcrm

###############################################################################
# Stage 2: Final runtime image
###############################################################################
FROM ubuntu:22.04

LABEL maintainer="feproappdev"
LABEL description="ChurchCRM - All-in-one Docker image with Apache, PHP, and MariaDB"

ENV DEBIAN_FRONTEND=noninteractive

# Database configuration - can be overridden at runtime
ENV DATABASE_NAME=churchcrm \
    DATABASE_USERNAME=churchcrm \
    DATABASE_PASSWORD=churchcrm_password \
    DATABASE_ROOT_PASSWORD=root_password

# Install all required packages
RUN apt-get update && apt-get install -y \
    apache2 \
    curl \
    gawk \
    libapache2-mod-php \
    mariadb-server \
    mariadb-client \
    php \
    php-bcmath \
    php-cli \
    php-curl \
    php-dev \
    php-gd \
    php-intl \
    php-mbstring \
    php-mysql \
    php-soap \
    php-xml \
    php-zip \
    supervisor \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Get PHP version for config path
RUN PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION. ". ".PHP_MINOR_VERSION;') && \
    echo "PHP_VERSION=$PHP_VERSION" > /etc/environment

# Copy ChurchCRM from builder stage
COPY --from=builder /opt/churchcrm /var/www/html/churchcrm

# Set proper ownership
RUN chown -R www-data:www-data /var/www/html/churchcrm

# Create PHP configuration
RUN PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".". PHP_MINOR_VERSION;') && \
    mkdir -p /etc/php/${PHP_VERSION}/apache2/conf.d && \
    cat > /etc/php/${PHP_VERSION}/apache2/conf.d/99-churchcrm.ini << 'EOF'
file_uploads = On
allow_url_fopen = On
short_open_tag = On
memory_limit = 256M
upload_max_filesize = 100M
post_max_size = 100M
max_execution_time = 360
date.timezone = UTC
EOF

# Create Apache virtual host configuration
RUN cat > /etc/apache2/sites-available/churchcrm.conf << 'EOF'
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html/churchcrm/
    ServerName ChurchCRM

    <Directory /var/www/html/churchcrm/>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

# Enable Apache modules and sites
RUN a2enmod rewrite && \
    a2dissite 000-default.conf && \
    a2ensite churchcrm.conf

# Create directories for MariaDB
RUN mkdir -p /var/run/mysqld && \
    chown -R mysql:mysql /var/run/mysqld && \
    chmod 755 /var/run/mysqld

# Create supervisor configuration
RUN mkdir -p /var/log/supervisor && \
    cat > /etc/supervisor/conf.d/supervisord.conf << 'EOF'
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

[program:mariadb]
command=/usr/bin/mysqld_safe
autostart=true
autorestart=true
user=mysql
stdout_logfile=/var/log/supervisor/mariadb.log
stderr_logfile=/var/log/supervisor/mariadb_err.log

[program:apache2]
command=/usr/sbin/apache2ctl -DFOREGROUND
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/apache2.log
stderr_logfile=/var/log/supervisor/apache2_err.log
EOF

# Create startup script
RUN cat > /usr/local/bin/startup.sh << 'STARTUP'
#!/bin/bash
set -e

# Initialize MariaDB data directory if empty
if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo "Initializing MariaDB data directory..."
    mysql_install_db --user=mysql --datadir=/var/lib/mysql
fi

# Start MariaDB temporarily for setup
echo "Starting MariaDB for initial setup..."
/usr/bin/mysqld_safe &
sleep 5

# Wait for MariaDB to be ready
until mysqladmin ping &>/dev/null; do
    echo "Waiting for MariaDB to start..."
    sleep 2
done

# Check if database exists, if not create it
if ! mysql -uroot -e "USE ${DATABASE_NAME}" 2>/dev/null; then
    echo "Creating database and user..."
    mysql -uroot << EOSQL
-- Set root password
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DATABASE_ROOT_PASSWORD}';
FLUSH PRIVILEGES;

-- Create database
CREATE DATABASE IF NOT EXISTS ${DATABASE_NAME} CHARACTER SET utf8 COLLATE utf8_unicode_ci;

-- Create user and grant privileges
CREATE USER IF NOT EXISTS '${DATABASE_USERNAME}'@'localhost' IDENTIFIED BY '${DATABASE_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DATABASE_NAME}.* TO '${DATABASE_USERNAME}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOSQL
    echo "Database setup complete."
else
    echo "Database already exists, skipping creation."
fi

# Stop the temporary MariaDB instance
mysqladmin -uroot -p"${DATABASE_ROOT_PASSWORD}" shutdown || mysqladmin -uroot shutdown || true
sleep 2

echo "Starting services via supervisor..."
exec /usr/bin/supervisord -c /etc/supervisor/conf. d/supervisord.conf
STARTUP

RUN chmod +x /usr/local/bin/startup.sh

# Create volume mount points for persistence
VOLUME ["/var/lib/mysql", "/var/www/html/churchcrm"]

# Expose HTTP port
EXPOSE 80

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/ || exit 1

# Start everything
CMD ["/usr/local/bin/startup.sh"]
