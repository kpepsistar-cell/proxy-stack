FROM python:3.12-alpine

WORKDIR /app

RUN apk add --no-cache curl docker-cli && \
    pip install --no-cache-dir flask qrcode pillow

COPY . /app
RUN mkdir -p /app/static

EXPOSE 5000

CMD ["python", "/app/app.py"]
