#Это так называемый мультистейдж docker-файл. Сначала делаем образ, который соберёт нам java-приложение,
#а затем из него берём собранный артефакт и кладём его в новый образ, чтобы оставить в нём меньше лишнего

# build
FROM maven:3.8.8-eclipse-temurin-17 AS builder
ARG VERSION=latest
ENV VERSION=${VERSION}
WORKDIR /usr/src/app
COPY ./src ./src
COPY *.xml ./

RUN mvn package

# release
FROM eclipse-temurin:17-jre-alpine
ARG VERSION=latest
WORKDIR /app
# создаём пользователя jaruser
RUN addgroup -S jaruser \
    && adduser -S -s /bin/false -G jaruser jaruser \
    && apk add --no-cache dumb-init curl \
    && mkdir -p /logs/reports \
    && chown -R jaruser:jaruser /logs
COPY --chown=jaruser:jaruser \
     --from=builder /usr/src/app/target/sausage-store-${VERSION}.jar ./sausage-store.jar
EXPOSE 8080
# приложение будет запускаться под пользователем jaruser
USER jaruser
ENTRYPOINT ["dumb-init", "java", "-jar", "-Dmyserver.bindPort=8080", "./sausage-store.jar"]
