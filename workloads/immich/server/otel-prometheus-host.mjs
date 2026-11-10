// Workaround for Immich v3.4.x: @opentelemetry/exporter-prometheus >= 0.300 binds to
// "localhost" by default and Immich passes no host, so Prometheus can no longer scrape
// 8081/8082 from the pod IP. Preloaded via NODE_OPTIONS=--import before dist/main.js.
// Remove once https://github.com/immich-app/immich/issues/33173 is fixed upstream.
import { PrometheusExporter } from '@opentelemetry/exporter-prometheus';

PrometheusExporter.DEFAULT_OPTIONS.host = process.env.OTEL_PROMETHEUS_BIND_HOST || '0.0.0.0';
