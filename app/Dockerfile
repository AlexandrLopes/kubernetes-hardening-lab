# Build the application image as an unprivileged user with no build tooling in
# the final layer. The base image is pinned by digest so every build of this tag
# produces the same base.
FROM python:3.13-alpine@sha256:2d9aefe2fef018a7eb2c13064c89c71929800fd2e5dccdbf52ea5da5bb8d929a

RUN adduser -D -u 10001 -s /sbin/nologin app

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --require-hashes=false -r requirements.txt \
    && rm -rf /root/.cache

COPY main.py .

USER 10001
EXPOSE 8080
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
CMD ["python", "main.py"]
