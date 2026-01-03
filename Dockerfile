###############################################################################
# Stage 1: Download and prepare ChurchCRM
###############################################################################
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    unzip \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp

# Download latest ChurchCRM release
RUN VERSION=$(curl -Is https://github.com/ChurchCRM/CRM/releases/latest | awk -F/ '/^location:/ {sub(/\r$/, "", $NF); print $NF}') && \
    echo "Downloading ChurchCRM version: $VERSION" && \
    curl -L -o ChurchCRM.zip "https://github.com/ChurchCRM/CRM/releases/download/$VERSION/ChurchCRM-$VERSION.zip" && \
    unzip ChurchCRM.zip && \
    rm ChurchCRM.zip && \
    mv churchcrm /opt/churchcrm

###############################################################################
# Stage 2: Final runtime image with PHP 8.3 (Ubuntu 24.04)
###############################################################################
FROM ubuntu:24.04

LABEL maintainer="feproappdev"
LABEL description="ChurchCRM - All-in-one Docker image with Apache, PHP 8.3, and MariaDB"

ENV DEBIAN_FRONTEND=noninteractive

# Database configuration - can be overridden at runtime
ENV DATABASE_NAME=churchcrm \
    DATABASE_USERNAME=churchcrm \
    DATABASE_PASSWORD=churchcrm_password \
    DATABASE_ROOT_PASSWORD=root_password

# Install all required packages (Ubuntu 24.04 has PHP 8.3)
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
RUN PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;') && \
    echo "PHP_VERSION=$PHP_VERSION" > /etc/environment && \
    echo "Installed PHP version: $PHP_VERSION"

# Copy ChurchCRM from builder stage
COPY --from=builder /opt/churchcrm /var/www/html/churchcrm

# Set proper ownership
RUN chown -R www-data:www-data /var/www/html/churchcrm

# Create PHP configuration
RUN PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;') && \
    mkdir -p /etc/php/${PHP_VERSION}/apache2/conf.d && \
    echo 'file_uploads = On' > /etc/php/${PHP_VERSION}/apache2/conf.d/99-churchcrm.ini && \
    echo 'allow_url_fopen = On' >> /etc/php/${PHP_VERSION}/apache2/conf.d/99-churchcrm.ini && \
    echo 'short_open_tag = On' >> /etc/php/${PHP_VERSION}/apache2/conf.d/99-churchcrm.ini && \
    echo 'memory_limit = 256M' >> /etc/php/${PHP_VERSION}/apache2/conf.d/99-churchcrm.ini && \
    echo 'upload_max_filesize = 100M' >> /etc/php/${PHP_VERSION}/apache2/conf.d/99-churchcrm.ini && \
    echo 'post_max_size = 100M' >> /etc/php/${PHP_VERSION}/apache2/conf.d/99-churchcrm.ini && \
    echo 'max_execution_time = 360' >> /etc/php/${PHP_VERSION}/apache2/conf.d/99-churchcrm.ini && \
    echo 'date.timezone = UTC' >> /etc/php/${PHP_VERSION}/apache2/conf.d/99-churchcrm.ini

# Create Apache virtual host configuration
RUN echo '<VirtualHost *:80>' > /etc/apache2/sites-available/churchcrm.conf && \
    echo '    ServerAdmin webmaster@localhost' >> /etc/apache2/sites-available/churchcrm.conf && \
    echo '    DocumentRoot /var/www/html/churchcrm/' >> /etc/apache2/sites-available/churchcrm.conf && \
    echo '    ServerName ChurchCRM' >> /etc/apache2/sites-available/churchcrm.conf && \
    echo '    <Directory /var/www/html/churchcrm/>' >> /etc/apache2/sites-available/churchcrm.conf && \
    echo '        Options -Indexes +FollowSymLinks' >> /etc/apache2/sites-available/churchcrm.conf && \
    echo '        AllowOverride All' >> /etc/apache2/sites-available/churchcrm.conf && \
    echo '        Require all granted' >> /etc/apache2/sites-available/churchcrm.conf && \
    echo '    </Directory>' >> /etc/apache2/sites-available/churchcrm.conf && \
    echo '    ErrorLog ${APACHE_LOG_DIR}/error.log' >> /etc/apache2/sites-available/churchcrm.conf && \
    echo '    CustomLog ${APACHE_LOG_DIR}/access.log combined' >> /etc/apache2/sites-available/churchcrm.conf && \
    echo '</VirtualHost>' >> /etc/apache2/sites-available/churchcrm.conf

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
    echo '[supervisord]' > /etc/supervisor/conf.d/supervisord.conf && \
    echo 'nodaemon=true' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo 'user=root' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo 'logfile=/var/log/supervisor/supervisord.log' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo 'pidfile=/var/run/supervisord.pid' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo '' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo '[program:mariadb]' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo 'command=/usr/bin/mysqld_safe' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo 'autostart=true' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo 'autorestart=true' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo 'user=mysql' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo 'stdout_logfile=/var/log/supervisor/mariadb.log' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo 'stderr_logfile=/var/log/supervisor/mariadb_err.log' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo '' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo '[program:apache2]' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo 'command=/usr/sbin/apache2ctl -DFOREGROUND' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo 'autostart=true' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo 'autorestart=true' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo 'stdout_logfile=/var/log/supervisor/apache2.log' >> /etc/supervisor/conf.d/supervisord.conf && \
    echo 'stderr_logfile=/var/log/supervisor/apache2_err.log' >> /etc/supervisor/conf.d/supervisord.conf

# Create startup script
COPY <<-'STARTUP' /usr/local/bin/startup.sh
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
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DATABASE_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS ${DATABASE_NAME} CHARACTER SET utf8 COLLATE utf8_unicode_ci;
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
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
STARTUP

RUN chmod +x /usr/local/bin/startup.sh

# Create volume mount points for persistence
VOLUME ["/var/lib/mysql", "/var/www/html/churchcrm"]

# Expose HTTP port
EXPOSE 80

# No health check - let Coolify manage it
# HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
#     CMD curl -f http://localhost/ || exit 1

# Start everything
CMD ["/usr/local/bin/startup.sh"]
