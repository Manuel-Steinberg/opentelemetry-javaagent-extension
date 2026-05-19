# Measuring Energy Consumption and CO2 Emissions of Java Applications with OpenTelemetry

*How a single JVM startup parameter turns any Java application into a green software observatory*

---

## Why Energy Consumption Matters for Software Engineers

The IT industry accounts for [roughly 2–4% of global CO2 emissions](https://pmc.ncbi.nlm.nih.gov/articles/PMC8441580/)—comparable to [the aviation industry](https://www.iea.org/energy-system/transport/aviation). As software engineers we tend to optimise for throughput, latency, and reliability. Energy efficiency rarely makes it onto the sprint board. But with sustainability regulations tightening across the EU—most notably the [Corporate Sustainability Reporting Directive (CSRD)](https://eur-lex.europa.eu/eli/dir/2022/2464/oj/eng)—and customers increasingly scrutinising their digital carbon footprint, the question *"How much energy does my service actually consume?"* is becoming as important as *"How fast does it respond?"*.

The challenge: software itself does not consume energy—the hardware it runs on does. Quantifying the share attributable to a specific Java process, or to a single HTTP transaction, requires careful measurement and modelling. Two extra JVM flags and a Docker Compose file are all you need.

## The Tool: OpenTelemetry Java Agent Extension (OTJAE)

The [OpenTelemetry Java Agent Extension](https://github.com/RETIT/opentelemetry-javaagent-extension) (OTJAE) is an open-source extension for the official [OpenTelemetry Java Auto-Instrumentation Agent](https://github.com/open-telemetry/opentelemetry-java-instrumentation). It hooks into the established OpenTelemetry instrumentation pipeline to collect four resource-demand dimensions for every traced transaction:

| Dimension | Unit | Platform |
|-----------|------|----------|
| CPU time  | milliseconds | Linux, macOS, Windows |
| Heap allocation | bytes | Linux, macOS, Windows |
| Disk I/O (read + write) | bytes | Linux (kernel ≥ 3.14) |
| Network I/O (read + write) | bytes | Linux (kernel ≥ 3.14) |

From these measurements OTJAE derives energy consumption and CO2 equivalent (CO2e) emissions at both the **process level** and the **individual transaction level**. The energy model follows the [Cloud Carbon Footprint (CCF)](https://www.cloudcarbonfootprint.org/docs/methodology/) methodology, which is pre-loaded with instance data for AWS, Azure, and GCP, and supports custom on-premise hardware profiles.

A recent peer-reviewed study presented at FSE 2025 (*Brunnert, "Evaluating the Accuracy of Software Energy Consumption Models for Java Applications at Process and Transaction Levels"*) compared OTJAE against direct RAPL hardware measurements. The verdict: **at CPU utilisation levels above 50% the model predictions match hardware measurements with high accuracy**. For cloud workloads—where direct hardware access via Intel RAPL is typically unavailable—OTJAE is currently one of the very few tools that can produce per-transaction energy estimates at all.

## How the Model Works

![Per-transaction resource demand capture across applications](../img/extension_data_capture.png)

*Figure 1: OTJAE captures CPU, memory, storage, and network demand independently for every transaction across all instrumented applications.*

In plain terms: the model estimates each transaction's share of the server's power bill based on how much CPU time it consumed relative to the total workload. The more CPU cycles your endpoint burns, the larger its slice of the energy cost.

OTJAE implements a linear power model from Etsy's [*Cloud Jewels*](https://www.etsy.com/codeascraft/cloud-jewels-estimating-kwh-in-the-cloud) methodology. Given the minimum idle power (P_min) and maximum full-load power (P_max) of the underlying processor, the instantaneous CPU power is:

```
P_CPU = P_min + (CPU_utilisation × (P_max − P_min))
```

For a single transaction the CPU utilisation is derived from the sum of CPU-time samples recorded during the measurement window:

```
CPU_util_transaction = Σ(dCPU) / (CPU_cores × interval_ms)
```

The same proportional split is applied to memory, storage, and network energy consumption. Carbon emissions are calculated by multiplying the energy value with the grid emissions factor (gCO2e/kWh) for the configured cloud region, plus a share of the hardware's embodied emissions amortised over its expected lifespan.

For cloud deployments (AWS, Azure, GCP) all coefficients—instance TDP, memory power, embodied emissions, grid factors—are pre-loaded from the CCF dataset. For on-premise hardware every parameter can be overridden via system properties.

## Instrumenting and Configuration your application with just two JVM flags

OTJAE's **zero-code instrumentation model** requires just two additional JVM arguments at startup — no application changes needed!

### Step 1 — Download the JARs

```bash
# OpenTelemetry Java Agent (base agent)
curl -L -o opentelemetry-javaagent.jar \
  https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar

# RETIT Extension (the energy/CO2 layer)
curl -L -o io.retit.opentelemetry.javaagent.extension.jar \
  https://github.com/RETIT/opentelemetry-javaagent-extension/releases/latest/download/io.retit.opentelemetry.javaagent.extension.jar
```

### Step 2 — Add the JVM Flags

```bash
java \
  -javaagent:./opentelemetry-javaagent.jar \
  -Dotel.javaagent.extensions=./io.retit.opentelemetry.javaagent.extension.jar \
  -Dotel.service.name=your-service \
  -jar ./your-application.jar
```

That's it! The extension hooks into every OpenTelemetry span and enriches it with resource demand attributes.

### Step 3 — Configure the Cloud or Hardware Profile

Without a cloud profile the extension still captures CPU and memory demand, but cannot produce emissions estimates. Three additional properties cover any cloud provider:

```bash
java \
  -javaagent:./opentelemetry-javaagent.jar \
  -Dotel.javaagent.extensions=./io.retit.opentelemetry.javaagent.extension.jar \
  -Dotel.service.name=your-service \
  -Dio.retit.emissions.cloud.provider=aws \
  -Dio.retit.emissions.cloud.provider.region=eu-central-1 \
  -Dio.retit.emissions.cloud.provider.instance.type=m5.xlarge \
  -jar ./your-application.jar
```

The pattern is the same for GCP and Azure — swap `aws` for `gcp` or `azure`, then adjust the region string and instance type. For on-premise deployments, replace the cloud properties with idle and peak CPU power values (available from [SPECpower_ssj2008](https://www.spec.org/power_ssj2008/results/) results), a PUE value for your data centre, and the grid emissions factor for your country. The [German grid factor for 2024](https://www.umweltbundesamt.de/themen/co2-emissionen-pro-kilowattstunde-strom-2024) is approximately 363 g CO2e/kWh (down from 433 in 2022, reflecting the growing share of renewables).

## Configuration Reference

The most important properties are the three cloud/hardware identifiers above, plus two opt-in capture flags: disk and network I/O are disabled by default because they require Linux kernel ≥ 3.14.

| System Property | Default | Description |
|----------------|---------|-------------|
| `io.retit.log.cpu.demand` | `true` | Capture CPU time per span |
| `io.retit.log.heap.demand` | `true` | Capture heap allocation per span |
| `io.retit.log.disk.demand` | `false` | Capture disk I/O per span (Linux only) |
| `io.retit.log.network.demand` | `false` | Capture network I/O per span (Linux only) |
| `io.retit.emissions.cloud.provider` | — | `aws`, `azure`, `gcp`, or `OnPremise` |
| `io.retit.emissions.cloud.provider.region` | — | Cloud region string |
| `io.retit.emissions.cloud.provider.instance.type` | — | VM instance type (e.g. `m5.xlarge`) |

All properties can also be set as environment variables (replace dots with underscores, uppercase), which is convenient for containerised deployments. The complete property reference—including on-premise power and embodied-emissions overrides—is in the [repository README](https://github.com/RETIT/opentelemetry-javaagent-extension).

## The Example Application: Spring REST Service

The repository of OTJAE ships with a ready-to-run [Spring Boot example application](https://github.com/RETIT/opentelemetry-javaagent-extension/tree/main/examples/spring-rest-service) — the same one used in the FSE 2025 accuracy study. The service exposes three REST endpoints that deliberately generate measurable resource load:

```
GET    http://localhost:8081/test-rest-endpoint/getData
POST   http://localhost:8081/test-rest-endpoint/postData
DELETE http://localhost:8081/test-rest-endpoint/deleteData
```

Each endpoint sorts an integer array of increasing size (3.000 / 4.000 / 6.000 elements) using a naïve O(n²) algorithm, writes a temporary file, and deletes it again—making the three transaction types distinguishable by their CPU, disk, and memory footprint.

```bash
# Build the project first
./mvnw clean package -pl examples/spring-rest-service

# Start the monitoring backend (Prometheus + Grafana + OTel Collector)
docker compose -f examples/docker/docker-compose.yml up -d

# Run the instrumented application (AWS eu-central-1, t3.medium)
java \
  -javaagent:./target/jib/otel/opentelemetry-javaagent.jar \
  -Dotel.service.name=spring-app \
  -Dotel.javaagent.extensions=./target/jib/otel/io.retit.opentelemetry.javaagent.extension.jar \
  -Dio.retit.emissions.cloud.provider=aws \
  -Dio.retit.emissions.cloud.provider.region=eu-central-1 \
  -Dio.retit.emissions.cloud.provider.instance.type=t3.medium \
  -jar examples/spring-rest-service/target/spring-rest-service.jar
```

Open `http://localhost:3000/grafana/dashboards` in your browser to see live resource demand and emissions data.

![Spring REST service Grafana dashboard showing SCI CO2eq per transaction, CPU demand, and emission calculation factors](../img/spring_dashboard.png)

*Figure 3: The pre-built Spring dashboard shows SCI (Software Carbon Intensity) in gCO2eq for each transaction type, CPU demand per transaction and for the whole process, plus the emission calculation factors used.*

The dashboard makes the contrast between endpoints immediately visible: the DELETE endpoint — sorting 6.000 elements with an O(n²) algorithm — registers roughly 3–4× more CPU time per request than GET, reflected directly in its CO2e share. For a service processing 10 million requests per day, that ratio compounds fast. Replacing the naïve sort with a standard O(n log n) algorithm would cut DELETE's energy footprint by more than half—and the improvement shows up in the dashboard within seconds of redeployment.

## Understanding the Dashbord Metrics

OTJAE publishes two categories of OpenTelemetry metrics.

**Resource demand counters** are cumulative values per service that grow over time—one counter each for CPU time (ms), heap allocation (bytes), disk I/O (bytes), and network I/O (bytes). Grafana's `rate()` function converts these into per-second or per-request demand figures.

**Emissions configuration gauges** are static values published once at startup: idle and peak CPU power, the grid emissions factor, PUE, and per-unit energy coefficients for memory, storage, and network. The Grafana dashboards use these as parameters to compute CO2e on the fly, so no pre-aggregation happens inside the JVM.

Every span also carries **resource demand as span attributes**—start and end readings for CPU time, heap bytes, disk reads/writes, and network reads/writes. This enables trace-level energy profiling: open a single slow request in Jaeger, inspect its span tree, and see exactly how much CPU time or heap each method call in the chain consumed.

The full metric names and attribute keys are listed in the [repository README](https://github.com/RETIT/opentelemetry-javaagent-extension).

## Accuracy: What to Expect

**At the process level**, the OTJAE linear model achieves the following accuracy compared to direct INTEL`s RAPL hardware measurements on a dual-socket Intel Xeon server:

| CPU Utilisation | OTJAE Accuracy |
|----------------|----------------|
| ~25%  (150 T/s) | 59.4% |
| ~52%  (300 T/s) | 75.8% |
| ~80%  (450 T/s) | 89.8% |
| ~98%  (600 T/s) | 98.1% |

**At the transaction level**, a similar pattern holds: results for GET, POST, and DELETE transactions from OTJAE align closely with JoularJX (RAPL-based Java reference) starting at around 50% system CPU utilisation.

The accuracy gap at low utilisation is well understood: the linear model does not capture the non-linearity in power consumption at near-idle load, where components outside the CPU—disks, RAID controllers, NICs, BMC—account for a disproportionate share of power draw.

**Practical recommendation**: if your services regularly operate below 30–40% CPU utilisation, treat OTJAE measurements as a lower-bound estimate. At medium to high load the model is production-grade.

## Limitations to Know About

**Thread model**: OTJAE measures resource demand per span by comparing start and end readings on the carrier thread. If a span hops between threads—common in reactive frameworks (Project Reactor, RxJava) or with virtual threads under heavy continuation switching—the delta calculation becomes invalid. The extension detects this condition and excludes such spans from metric aggregation (the raw span attributes are still attached for manual inspection).

**Operating system scope**: Disk and network demand capture require Linux with kernel ≥ 3.14. On macOS and Windows only CPU and memory demand are available.

**Virtual threads (Project Loom)**: Memory demand cannot be captured for virtual threads due to JVM limitations. CPU demand uses the carrier thread as a proxy, which may overestimate for workloads with many parked virtual threads.

## Going Further

Once you have the basic setup running there are several natural next steps:

1. **Add load testing** — the example application ships with an Apache JMeter script. Run it against your instrumented service and watch the dashboards respond in real time.

2. **Tune the instance configuration** — switch the cloud provider region from `eu-central-1` (low carbon grid) to a coal-heavy region and observe how the CO2 estimate changes without touching the application at all.

3. **Integrate into CI/CD** — the OpenTelemetry metrics endpoint is standard. Add an energy budget assertion to your performance tests: fail the build if a key transaction's CPU demand per request exceeds a defined threshold.

4. **Explore embodied emissions** — set `io.retit.emissions.hardware.lifespan` to different values (3–6 years) to understand how hardware refresh cycles affect your total CO2 footprint.

## Conclusion

For cloud environments where direct hardware measurements via Intel RAPL are inaccessible, OTJAE is currently one of the most practical options for per-transaction energy attribution—validated against hardware measurements in a peer-reviewed study and ready to deploy with two JARs and no application code changes.

Green software engineering starts with measurement. Now you have the tools.

---

*The source code, examples, and pre-built dashboards are available at [github.com/RETIT/opentelemetry-javaagent-extension](https://github.com/RETIT/opentelemetry-javaagent-extension) under the Apache 2.0 license.*