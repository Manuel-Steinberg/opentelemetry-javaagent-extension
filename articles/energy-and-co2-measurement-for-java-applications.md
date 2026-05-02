# Measuring Energy Consumption and CO2 Emissions of Java Applications with OpenTelemetry

*How a single JVM startup parameter turns any Java application into a green software observatory*

---

## Why Energy Consumption Matters for Software Engineers

The IT industry accounts for roughly 2–4% of global CO2 emissions—comparable to the aviation industry. As software engineers we tend to optimise for throughput, latency, and reliability. Energy efficiency rarely makes it onto the sprint board. But with sustainability regulations tightening across the EU and customers increasingly scrutinising their digital carbon footprint, the question *"How much energy does my service actually consume?"* is becoming as important as *"How fast does it respond?"*.

The tricky part: software itself does not consume energy. It is the hardware the software runs on that does. Quantifying the share of energy attributable to a specific Java process—or even to a specific HTTP transaction—requires careful measurement and modelling. This article shows how to do exactly that, with nothing more than two extra JVM flags and a Docker Compose file.

---

## The Tool: OpenTelemetry Java Agent Extension (OTJAE)

The [OpenTelemetry Java Agent Extension](https://github.com/RETIT/opentelemetry-javaagent-extension) (OTJAE) is an open-source extension for the official [OpenTelemetry Java Auto-Instrumentation Agent](https://github.com/open-telemetry/opentelemetry-java-instrumentation). It piggybacks on the established OpenTelemetry instrumentation pipeline to collect four resource-demand dimensions for every traced transaction:

| Dimension | Unit | Platform |
|-----------|------|----------|
| CPU time  | milliseconds | Linux, macOS, Windows |
| Heap allocation | bytes | Linux, macOS, Windows |
| Disk I/O (read + write) | bytes | Linux (kernel ≥ 3.14) |
| Network I/O (read + write) | bytes | Linux (kernel ≥ 3.14) |

From these measurements OTJAE derives energy consumption and CO2 equivalent (CO2e) emissions at both the **process level** and the **individual transaction level**. The energy model follows the [Cloud Carbon Footprint (CCF)](https://www.cloudcarbonfootprint.org/docs/methodology/) methodology, which is pre-loaded with instance data for AWS, Azure, and GCP, and supports custom on-premise hardware profiles.

A recent peer-reviewed study presented at FSE 2025 (*Brunnert, "Evaluating the Accuracy of Software Energy Consumption Models for Java Applications at Process and Transaction Levels"*) compared OTJAE against direct RAPL hardware measurements. The verdict: **at CPU utilisation levels above 50% the model predictions match hardware measurements with high accuracy**. For cloud workloads—where direct hardware access via Intel RAPL is typically unavailable—OTJAE is currently one of the very few tools that can produce per-transaction energy estimates at all.

---

## How the Model Works

![Per-transaction resource demand capture across applications](../img/extension_data_capture.png)

*Figure 1: OTJAE captures CPU, memory, storage, and network demand independently for every transaction across all instrumented applications.*

OTJAE implements a linear power model from Etsy's *Cloud Jewels* methodology. Given the minimum idle power (P_min) and maximum full-load power (P_max) of the underlying processor, the instantaneous CPU power is:

```
P_CPU = P_min + (CPU_utilisation × (P_max − P_min))
```

This value is then split proportionally across processes and—within a process—across individual transactions based on their measured CPU time.

For a single transaction the CPU utilisation is derived from the sum of CPU-time samples recorded during the measurement window:

```
CPU_util_transaction = Σ(dCPU) / (CPU_cores × interval_ms)
```

The same proportional split is applied to memory, storage, and network energy consumption. Carbon emissions are calculated by multiplying the energy value with the grid emissions factor (gCO2e/kWh) for the configured cloud region, plus a share of the hardware's embodied emissions amortised over its expected lifespan.

![From transaction measurements to software energy consumption and carbon emissions via the CCF methodology](../img/energy_emission_calculations.png)

*Figure 2: Resource demand measurements from every transaction flow through the Cloud Carbon Footprint (CCF) methodology to produce energy and CO2e values.*

For cloud deployments (AWS, Azure, GCP) all coefficients—instance TDP, memory power, embodied emissions, grid factors—are pre-loaded from the CCF dataset. For on-premise hardware every parameter can be overridden via system properties.

---

## Instrumenting Your Application: Just Two JVM Flags

The great advantage of OTJAE is the **zero-code instrumentation model**. You do not change a single line of application code. All you need are two additional JVM arguments at startup.

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
  -Dotel.service.name=my-service \
  -jar ./my-application.jar
```

That's it. The extension automatically hooks into every OpenTelemetry span created by the base agent and enriches it with resource demand attributes.

### Step 3 — Configure the Cloud/Hardware Profile

Without a cloud profile the extension still captures CPU and memory demand, but cannot produce emissions estimates. Specify the target environment with three additional properties:

**AWS example:**

```bash
java \
  -javaagent:./opentelemetry-javaagent.jar \
  -Dotel.javaagent.extensions=./io.retit.opentelemetry.javaagent.extension.jar \
  -Dotel.service.name=my-service \
  -Dio.retit.emissions.cloud.provider=aws \
  -Dio.retit.emissions.cloud.provider.region=eu-central-1 \
  -Dio.retit.emissions.cloud.provider.instance.type=m5.xlarge \
  -jar ./my-application.jar
```

**GCP example:**

```bash
java \
  -javaagent:./opentelemetry-javaagent.jar \
  -Dotel.javaagent.extensions=./io.retit.opentelemetry.javaagent.extension.jar \
  -Dotel.service.name=my-service \
  -Dio.retit.emissions.cloud.provider=gcp \
  -Dio.retit.emissions.cloud.provider.region=europe-west3 \
  -Dio.retit.emissions.cloud.provider.instance.type=n2-standard-4 \
  -jar ./my-application.jar
```

**On-premise example** (custom hardware, German grid):

```bash
java \
  -javaagent:./opentelemetry-javaagent.jar \
  -Dotel.javaagent.extensions=./io.retit.opentelemetry.javaagent.extension.jar \
  -Dotel.service.name=my-service \
  -Dio.retit.emissions.cloud.provider=OnPremise \
  -Dio.retit.emissions.onpremise.cpu.power.idle=25.02 \
  -Dio.retit.emissions.onpremise.cpu.power.100=116.91 \
  -Dio.retit.emissions.onpremise.instance.vcpu.count=20 \
  -Dio.retit.emissions.onpremise.platform.total.vcpu.count=20 \
  -Dio.retit.emissions.onpremise.grid.emissions.factor=485.0 \
  -Dio.retit.emissions.onpremise.pue=1.43 \
  -jar ./my-application.jar
```

The idle/full-load power values for the CPU can be obtained from [SPECpower_ssj2008](https://www.spec.org/power_ssj2008/results/) results. The German grid emissions factor for 2024 is approximately 485 g CO2e/kWh.

---

## Configuration Reference

All properties can also be set as environment variables (replace dots with underscores and use uppercase), which is convenient for containerised deployments.

| System Property | Environment Variable | Default | Description |
|----------------|---------------------|---------|-------------|
| `io.retit.log.cpu.demand` | `IO_RETIT_LOG_CPU_DEMAND` | `true` | Capture CPU time per span |
| `io.retit.log.heap.demand` | `IO_RETIT_LOG_HEAP_DEMAND` | `true` | Capture heap allocation per span |
| `io.retit.log.disk.demand` | `IO_RETIT_LOG_DISK_DEMAND` | `false` | Capture disk I/O per span (Linux only) |
| `io.retit.log.network.demand` | `IO_RETIT_LOG_NETWORK_DEMAND` | `false` | Capture network I/O per span (Linux only) |
| `io.retit.emissions.cloud.provider` | `IO_RETIT_EMISSIONS_CLOUD_PROVIDER` | — | `aws`, `azure`, `gcp`, `OnPremise` |
| `io.retit.emissions.cloud.provider.region` | `IO_RETIT_EMISSIONS_CLOUD_PROVIDER_REGION` | — | Cloud region string |
| `io.retit.emissions.cloud.provider.instance.type` | `IO_RETIT_EMISSIONS_CLOUD_PROVIDER_INSTANCE_TYPE` | — | VM instance type (e.g. `m5.xlarge`) |
| `io.retit.emissions.storage.type` | `IO_RETIT_EMISSIONS_STORAGE_TYPE` | `SSD` | `SSD` or `HDD` |
| `io.retit.emissions.hardware.lifespan` | `IO_RETIT_EMISSIONS_HARDWARE_LIFESPAN` | `4.0` | Hardware lifespan in years |
| `io.retit.emissions.onpremise.pue` | `IO_RETIT_EMISSIONS_ONPREMISE_PUE` | `1.43` | Power Usage Effectiveness |
| `io.retit.emissions.onpremise.grid.emissions.factor` | `IO_RETIT_EMISSIONS_ONPREMISE_GRID_EMISSIONS_FACTOR` | `342.0` | Grid emissions factor (g CO2e/kWh) |

---

## The Example Application: Spring REST Service

The repository ships with a ready-to-run [Spring Boot example application](https://github.com/RETIT/opentelemetry-javaagent-extension/tree/main/examples/spring-rest-service). It is the same application used in the FSE 2025 accuracy study. The service exposes three REST endpoints that deliberately generate measurable resource load:

```
GET    http://localhost:8081/test-rest-endpoint/getData
POST   http://localhost:8081/test-rest-endpoint/postData
DELETE http://localhost:8081/test-rest-endpoint/deleteData
```

Each endpoint sorts an integer array of increasing size (3 000 / 4 000 / 6 000 elements) using a naïve O(n²) algorithm, writes a temporary file, and deletes it again. This makes the three transaction types distinguishable by their CPU, disk, and memory footprint—ideal for exploring the dashboards.

Starting the example with instrumentation:

```bash
# Build the project first
./mvnw clean package -pl examples/spring-rest-service

# Start the monitoring backend (Prometheus + Grafana + OTel Collector)
cd examples
docker compose -f ./docker/docker-compose.yml up -d

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

Once running, point your browser at `http://localhost:3000/grafana/dashboards` to see the pre-built Grafana dashboard with live resource demand and emissions data.

![Spring REST service Grafana dashboard showing SCI CO2eq per transaction, CPU demand, and emission calculation factors](../img/spring_dashboard.png)

*Figure 4: The pre-built Spring dashboard shows SCI (Software Carbon Intensity) in gCO2eq for each transaction type, CPU demand per transaction and for the whole process, plus the emission calculation factors used.*

---

## What Flows Through the Pipeline

![Demo architecture: Application to Grafana via OpenTelemetry Collector and Prometheus](../img/demo_architecture.png)

*Figure 3: The instrumented application sends resource demand and emissions data via OTLP to the OpenTelemetry Collector, which feeds Prometheus as a metrics store and Grafana as the visualisation layer.*

The Docker Compose file in `examples/docker/` brings up all backend services with a single command:

```bash
docker compose -f examples/docker/docker-compose.yml up -d
```

The OpenTelemetry Collector is pre-configured to scrape on ports 4317/4318 and export to Prometheus on port 9464. Prometheus is configured with a 5-second scrape interval, ensuring near-real-time dashboards.

---

## Understanding the Metrics

OTJAE publishes two categories of OpenTelemetry metrics.

**Resource demand counters** — cumulative values per service, growing over time:

```
io.retit.resource.demand.cpu.ms        # CPU time consumed (milliseconds)
io.retit.resource.demand.memory.bytes  # Heap allocated (bytes)
io.retit.resource.demand.storage.bytes # Disk I/O (bytes)
io.retit.resource.demand.network.bytes # Network I/O (bytes)
```

**Emissions configuration gauges** — static values published once, used as parameters for Grafana calculations:

```
io.retit.emissions.cpu.power.min          # Idle CPU power (Watts)
io.retit.emissions.cpu.power.max          # Max CPU power at 100% load (Watts)
io.retit.emissions.gef                    # Grid Emissions Factor (g CO2e/kWh)
io.retit.emissions.pue                    # Power Usage Effectiveness
io.retit.emissions.embodied.emissions.minute.mg  # Embodied emissions/minute (mg)
io.retit.emissions.memory.energy.gb.minute       # Memory energy/GB/minute (kWh)
io.retit.emissions.storage.energy.gb.minute      # Storage energy/GB/minute (kWh)
io.retit.emissions.network.energy.gb.minute      # Network energy/GB/minute (kWh)
```

In addition, every span carries **resource demand as span attributes**:

```
io.retit.startcputime / io.retit.endcputime
io.retit.startheapbyteallocation / io.retit.endheapbyteallocation
io.retit.startdiskreaddemand / io.retit.enddiskreaddemand
io.retit.startdiskwritedemand / io.retit.enddiskwritedemand
io.retit.startnetworkreaddemand / io.retit.endnetworkreaddemand
io.retit.startnetworkwritedemand / io.retit.endnetworkwritedemand
```

These span attributes allow trace-level energy profiling: you can open a single slow request in Jaeger, inspect its span tree, and see exactly how much CPU time or heap was consumed by each method call in the call chain.

---

## Accuracy: What to Expect

The FSE 2025 study gives practitioners a clear picture of where to trust the numbers.

**At the process level**, the OTJAE linear model achieves the following accuracy compared to direct RAPL hardware measurements on a dual-socket Intel Xeon server:

| CPU Utilisation | OTJAE Accuracy |
|----------------|----------------|
| ~25%  (150 T/s) | 59.4% |
| ~52%  (300 T/s) | 75.8% |
| ~80%  (450 T/s) | 89.8% |
| ~98%  (600 T/s) | 98.1% |

**At the transaction level**, a similar pattern holds: results for GET, POST, and DELETE transactions from OTJAE align closely with JoularJX (RAPL-based reference) starting at around 50% system CPU utilisation.

The root cause of the lower accuracy at idle/low-load is well understood: the linear model does not account for the non-linearity in power consumption at very low utilisation levels. A large portion of hardware power draw at idle is caused by components outside the CPU (disks, RAID controllers, NICs, BMC) that are invisible to a CPU-utilisation-based model.

**Practical recommendation**: if your services regularly operate below 30–40% CPU utilisation, treat OTJAE measurements as a lower-bound estimate rather than an exact figure. At medium to high load the model is production-grade.

---

## Limitations to Know About

**Thread model**: OTJAE measures resource demand per span by comparing start and end readings on the carrier thread. If a span hops between threads—common in reactive frameworks (Project Reactor, RxJava) or with virtual threads under heavy continuation switching—the delta calculation becomes invalid. The extension detects this condition and excludes such spans from metric aggregation (the raw span attributes are still attached for manual inspection).

**Operating system scope**: Disk and network demand capture require Linux with kernel ≥ 3.14. On macOS and Windows only CPU and memory demand are available.

**Virtual threads (Project Loom)**: Memory demand cannot be captured for virtual threads due to JVM limitations. CPU demand uses the carrier thread as a proxy, which may overestimate for workloads with many parked virtual threads.

---

## Going Further

Once you have the basic setup running there are several natural next steps:

1. **Add load testing** — the example application ships with an Apache JMeter script. Run it against your instrumented service and watch the dashboards respond in real time.

2. **Compare transaction types** — with distinct GET/POST/DELETE endpoints you can immediately see that the DELETE transaction consumes roughly 2–4× more CPU time than GET, directly reflected in its CO2 share.

3. **Tune the instance configuration** — try switching the cloud provider region from `eu-central-1` (low carbon grid) to a coal-heavy region and observe how the CO2 estimate changes without touching the application at all.

4. **Integrate into CI/CD** — the OpenTelemetry metrics endpoint is standard. You can add an energy budget assertion to your performance tests: fail the build if a key transaction's CPU demand per request exceeds a defined threshold.

5. **Explore embodied emissions** — set `io.retit.emissions.hardware.lifespan` to different values (3–6 years) to understand how hardware refresh cycles affect your total CO2 footprint.

---

## Conclusion

Measuring the energy consumption and carbon footprint of a Java application no longer requires specialised hardware, kernel modifications, or days of integration work. With OTJAE, the entire instrumentation is contained in two JARs and a handful of JVM flags—no application code changes required. The OpenTelemetry ecosystem takes care of the rest: data flows automatically from the JVM into Prometheus and surfaces in pre-built Grafana dashboards.

The FSE 2025 accuracy study confirms that the model is sufficiently precise for practical use at medium to high load levels, which matches the operating range of most production services. For cloud environments where direct hardware measurements via Intel RAPL are inaccessible, OTJAE currently stands as one of the most practical available options for per-transaction energy attribution.

Green software engineering starts with measurement. Now you have the tools.

---

*The source code, examples, and pre-built dashboards are available at [github.com/RETIT/opentelemetry-javaagent-extension](https://github.com/RETIT/opentelemetry-javaagent-extension) under the Apache 2.0 license.*

*The accuracy study is published as: Andreas Brunnert, "Evaluating the Accuracy of Software Energy Consumption Models for Java Applications at Process and Transaction Levels", FSE Companion '25, June 23–28, 2025, Trondheim, Norway. DOI: 10.1145/3696630.3728709*
