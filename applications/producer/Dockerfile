FROM python:3.11-slim

# Install Oracle Instant Client
RUN apt-get update && apt-get install -y \
    wget \
    unzip \
    libaio1 \
    && rm -rf /var/lib/apt/lists/*

# Download Oracle Instant Client
WORKDIR /opt/oracle
RUN wget https://download.oracle.com/otn_software/linux/instantclient/219000/instantclient-basic-linux.x64-21.9.0.0.0dbru.zip \
    && unzip instantclient-basic-linux.x64-21.9.0.0.0dbru.zip \
    && rm instantclient-basic-linux.x64-21.9.0.0.0dbru.zip

ENV LD_LIBRARY_PATH=/opt/oracle/instantclient_21_9:$LD_LIBRARY_PATH

# Install Python dependencies
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Create non-root user
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser /app
USER appuser

# Add health check endpoint
COPY health_server.py .

# Run the application
CMD ["python", "-m", "producer"]