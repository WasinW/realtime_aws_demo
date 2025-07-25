#  applications/pii-masking/Dockerfile
FROM openjdk:11-jre-slim

RUN apt-get update && apt-get install -y \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY target/pii-masking-1.0.0.jar /app/app.jar
COPY src/main/resources/log4j.properties /app/

ENV JAVA_OPTS="-Xmx2g -Xms1g -XX:+UseG1GC"

EXPOSE 8080

CMD ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]