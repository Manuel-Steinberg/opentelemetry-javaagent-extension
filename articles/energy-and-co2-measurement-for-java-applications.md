# Measuring Energy Consumption and CO2 Emissions of Java Applications with OpenTelemetry

*Two JVM flags or a single dependency turn a Java application into a green software observatory*

## Why Energy Consumption of Software should matter

The IT industry accounts for roughly 2–4% of global CO2 emissions [1] — comparable to aviation [2]. Most software developers optimise hard for throughput, latency, and reliability. Energy efficiency rarely makes it onto the sprint board.

This is going to change. Sustainability regulations are tightening across the EU, most notably with the Corporate Sustainability Reporting Directive (CSRD) [3], and customers are increasingly asking questions about the carbon footprint of the services they use. The question *"How much energy does the service actually consume?"* is becoming as commercially relevant as *"How fast does it respond?"*. The Green Software Foundation's **Software Carbon Intensity (SCI)** specification [16] ISO/IEC standard gives organisations a consistent way to answer it: gCO2eq per unit of work.

The awkward truth is that software itself does not consume energy; the hardware it runs on does. Attributing a share of hardware's power draw to a specific Java process, or to a single HTTP transaction, requires measurement and modelling.

Specialised tools like JoularJX can do this accurately by reading Intel's RAPL interface — a hardware mechanism that reports actual socket-level energy consumption in real time. The catch: RAPL requires direct hardware access, which disappears the moment you deploy to AWS, Google Cloud, or Azure. Most production Java workloads run precisely there. Model-based tools fill that gap. Instead of reading from hardware, they estimate energy consumption from metrics that *are* available in cloud environments — CPU time, heap allocation, disk and network I/O — and map them to power draw using known hardware profiles. Accuracy is not perfect across all load levels, but it is good enough for production use, and it requires no specialised infrastructure, no root access, and no changes to your application.

This article walks through one such tool — the OpenTelemetry Java Agent Extension (OTJAE) — and shows how to go from zero to per-transaction CO2 estimates in a matter of minutes.

## What OTJAE Does

The OpenTelemetry Java Agent Extension [4] — OTJAE — is an open-source add-on for the official OpenTelemetry Java auto-instrumentation agent [5]. The OTel agent is a required component in both integration options covered below; if you already use it, adding OTJAE is two extra flags or one dependency. It adds four resource-demand dimensions to every traced transaction:

| Dimension | Unit | Platform |
|-----------|------|----------|
| CPU time  | milliseconds | Linux, macOS, Windows |
| Heap allocation | bytes | Linux, macOS, Windows |
| Disk I/O (read + write) | bytes | Linux (kernel ≥ 3.14) |
| Network I/O (read + write) | bytes | Linux (kernel ≥ 3.14) |

All four feed an energy model that produces two outputs: **process-level** energy and CO2 consumption (useful for infrastructure cost attribution and sustainability reporting) and **per-transaction** energy and CO2 (useful for identifying which endpoints actually drive your power bill). The model uses the Cloud Carbon Footprint (CCF) [6] methodology and ships with pre-loaded coefficient tables for AWS, Azure, and GCP. On-premise hardware is supported too, with configurable parameters for CPU power, data-centre PUE (Power Usage Effectiveness, the ratio of total facility power to IT equipment power), and grid emissions factors.

A peer-reviewed study presented at FSE 2025 [7] validated OTJAE against direct Intel RAPL hardware measurements. RAPL is the hardware interface on Intel processors that reports actual socket-level energy consumption, but it is typically inaccessible in cloud environments. In cloud deployments, where direct hardware access is locked away, OTJAE is one of the few tools that can still tell you how much energy that last HTTP request actually cost.

## How the Numbers Are Calculated

Knowing how the model works tells you when to trust the numbers and when to be cautious.

![Per-transaction resource demand capture across applications](../img/extension_data_capture.png)

*Figure 1: OTJAE captures CPU, memory, storage, and network demand independently for every transaction across all instrumented applications.*

Each transaction gets a share of the server's power bill proportional to the CPU time it consumed. OTJAE implements the linear power model from Etsy's *Cloud Jewels* [8] paper, which estimates instantaneous CPU power as an interpolation between idle and full-load power:

```
P_CPU = P_min + (CPU_utilisation × (P_max − P_min))
```

For a single transaction, CPU utilisation is derived from the thread's CPU-time delta across the span:

```
CPU_util_transaction = Σ(dCPU) / (CPU_cores × interval_ms)
```

The same proportional logic applies to memory, disk, and network. Carbon emissions are then the energy value multiplied by the grid emissions factor (gCO2e/kWh) for the configured region, plus a pro-rated share of the hardware's embodied emissions — the carbon cost of manufacturing and eventually disposing of the hardware — amortised over its expected lifespan.

For cloud deployments all the coefficients you need — processor TDP (Thermal Design Power, the rated maximum heat output at full load), memory power, embodied emissions, and regional grid factors — come pre-loaded from the CCF dataset. This is why specifying the cloud provider, region, and instance type unlocks the full emissions picture: without those three values, the extension can measure resource demand but has no power envelope to map it to.

## Instrumenting Your Application

No application code changes are required. OTJAE supports two integration options, and both rely on the OpenTelemetry Java agent being active: Option A loads it via JVM flags, Option B relies on the framework's own OpenTelemetry integration. Either way, OTJAE hooks into the active OTel pipeline and enriches every span with resource-demand data.

Before starting either option, you need somewhere for the data to land. OTJAE exports standard OTel signals — metrics and span attributes — to any compatible backend. If you don't have one running already, the repository ships with a ready-to-go docker-compose stack (Prometheus, Grafana, and an OTel Collector):

```bash
docker compose -f examples/docker/docker-compose.yml up -d
```

That same stack powers the Spring example later in this article.

### Option A: JVM Flags (Spring Boot, plain JVM, legacy apps)

This works with any JVM application where you control startup parameters. You need two JARs and two flags.

#### Step 1 — Download the JARs

```bash
# OpenTelemetry Java Agent (base agent)
curl -L -o opentelemetry-javaagent.jar \
  https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar

# RETIT Extension (the energy/CO2 layer)
curl -L -o io.retit.opentelemetry.javaagent.extension.jar \
  https://github.com/RETIT/opentelemetry-javaagent-extension/releases/latest/download/io.retit.opentelemetry.javaagent.extension.jar
```

#### Step 2 — Start your application with the agent

```bash
java \
  -javaagent:./opentelemetry-javaagent.jar \
  -Dotel.javaagent.extensions=./io.retit.opentelemetry.javaagent.extension.jar \
  -Dotel.service.name=your-service \
  -jar ./your-application.jar
```

OTJAE is now active and capturing CPU and heap demand on every span, exporting to whatever OTel backend you have configured.

#### Step 3 — Add the cloud or hardware profile for emissions estimates

Without a cloud profile the extension captures resource demand but cannot convert it to energy or CO2 figures — it has no power envelope to work with. Three additional system properties cover any of the three major cloud providers:

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

The pattern is the same for GCP and Azure — swap `aws` for `gcp` or `azure` and adjust the region string and instance type. For on-premise hardware, replace the cloud properties with idle and peak CPU power values (available from SPECpower_ssj2008 [9] results), a PUE value for your data centre, and the grid emissions factor for your country. Germany's 2024 grid factor [10] is approximately 363 g CO2e/kWh, down from 433 in 2022 as the share of renewables has grown.

### Option B: Maven Dependency (Quarkus and CDI Frameworks)

If your application runs on a CDI-enabled framework such as Quarkus or WildFly, a newer addition to the project [4] lets you skip the JVM flags entirely. You add a Maven dependency and CDI's bean auto-discovery wires up the span processor automatically.

| | Java Agent (Option A) | CDI Library (Option B) |
|---|---|---|
| Spring Boot | Recommended | Not applicable |
| Quarkus | Works | Recommended |
| WildFly / Jakarta EE | Works | Recommended |
| Plain JVM / legacy apps | Only option | Not applicable |

One trade-off worth knowing upfront: the library is currently distributed via GitHub Packages rather than Maven Central, which means an authentication step that the JAR download approach doesn't require. The examples below use Maven; Gradle-based projects can consume the library from the same repository using standard Maven-compatible repository configuration — check the project repository [4] for the latest guidance.

#### Step 1 — Authenticate with GitHub Packages

GitHub Packages requires a personal access token (PAT) with the `read:packages` scope, even for public repositories. Add your credentials to `~/.m2/settings.xml`:

```xml
<settings>
  <servers>
    <server>
      <id>github</id>
      <username>YOUR_GITHUB_USERNAME</username>
      <password>YOUR_PAT_WITH_READ_PACKAGES</password>
    </server>
  </servers>
</settings>
```

Then declare the repository in your project `pom.xml`:

```xml
<repositories>
  <repository>
    <id>github</id>
    <name>GitHub RETIT Apache Maven Packages</name>
    <url>https://maven.pkg.github.com/RETIT/opentelemetry-javaagent-extension</url>
  </repository>
</repositories>
```

#### Step 2 — Add the dependency

```xml
<dependency>
  <groupId>io.retit</groupId>
  <artifactId>opentelemetry-java-agent-extension-cdi-library</artifactId>
  <version>v0.1.0-beta</version>
</dependency>
```

> **Note**: As of this writing, the CDI library is at v0.1.0-beta. Option A has a longer production track record. Check the releases page for the latest version before using this in production.

For Quarkus, `quarkus-opentelemetry` must also be on the classpath — it provides the SDK the CDI library hooks into and is typically already present in any Quarkus service that exports traces. Once the dependency is on the classpath, CDI finds `RETITSpanProcessorConfiguration` through the library's `META-INF/beans.xml` and registers the span processor with no additional wiring.

#### Step 3 — Configure via application.properties

The same OTJAE configuration properties work in CDI mode and can be set through Quarkus's standard `application.properties`:

```properties
io.retit.emissions.cloud.provider=aws
io.retit.emissions.cloud.provider.region=eu-central-1
io.retit.emissions.cloud.provider.instance.type=t3.medium
```

Environment variables work equally well (replace dots with underscores, uppercase). A complete working example is available in the repository's examples directory [11] alongside the Spring and plain-JDK variants.

## Configuration Reference

The table below covers the most commonly needed properties. Disk and network I/O are off by default because they require Linux kernel ≥ 3.14. On-premise parameters — CPU idle and peak power, PUE, grid emissions factor, embodied emissions — follow the same `-Dio.retit.*` naming pattern and are fully documented in the repository README [4].

| System Property | Default | Description |
|----------------|---------|-------------|
| `io.retit.log.cpu.demand` | `true` | Capture CPU time per span |
| `io.retit.log.heap.demand` | `true` | Capture heap allocation per span |
| `io.retit.log.disk.demand` | `false` | Capture disk I/O per span (Linux only) |
| `io.retit.log.network.demand` | `false` | Capture network I/O per span (Linux only) |
| `io.retit.log.gc.event` | `true` | Register a listener to capture garbage collection events |
| `io.retit.emissions.cloud.provider` | — | `aws`, `azure`, `gcp`, or `OnPremise` |
| `io.retit.emissions.cloud.provider.region` | — | Cloud region string |
| `io.retit.emissions.cloud.provider.instance.type` | — | VM instance type (e.g. `m5.xlarge`) |
| `io.retit.emissions.storage.type` | `SSD` | Storage type used for energy calculation (`HDD` or `SSD`) |
| `io.retit.emissions.hardware.lifespan` | `4` | Expected hardware lifespan in years (for embodied emissions amortisation) |

The complete reference — including on-premise overrides — is in the repository README [4].

## Reading the Metrics

OTJAE exports two categories of OpenTelemetry metrics, and understanding the distinction matters when you build dashboards or alerts on top of them.

**Resource demand counters** are cumulative totals per service instance that grow monotonically: one counter each for CPU time (ms), heap allocation (bytes), disk I/O (bytes), and network I/O (bytes). They are designed for rate functions: Grafana's `rate()` gives you per-second demand, and dividing by request rate gives you per-request demand.

**Emissions configuration gauges** are published once at startup and stay static: idle and peak CPU power, the grid emissions factor, PUE, and per-unit energy coefficients for memory, storage, and network. The pre-built dashboards use these as live parameters to compute CO2e in Grafana itself — no pre-aggregation happens inside the JVM.

Every span also carries **resource demand as span attributes**: start and end readings for CPU time, heap bytes, and I/O counters. That is what enables trace-level energy profiling: open a slow request in Jaeger, look at the span tree, and see exactly how much CPU or heap each method call in the chain consumed.

Full metric names and attribute keys are in the repository README [4].

## Seeing It in Practice

The repository ships with a ready-to-run Spring Boot example — the same application used in the FSE 2025 accuracy study [7]. It exposes three REST endpoints that deliberately differ in how much work they do:

```
GET    http://localhost:8081/test-rest-endpoint/getData
POST   http://localhost:8081/test-rest-endpoint/postData
DELETE http://localhost:8081/test-rest-endpoint/deleteData
```

> **Note on JAR paths**: The commands below reference `target/jib/otel/` paths, which are produced by the example project's Maven build, which downloads and stages both agent JARs automatically during `./mvnw clean package`. If you are adapting these commands to your own application, substitute the paths where you downloaded the JARs in Option A, Step 1 above.

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

*Figure 2: The pre-built Spring dashboard shows SCI (Software Carbon Intensity) in gCO2eq for each transaction type, CPU demand per transaction and for the whole process, plus the emission calculation factors used.*

The dashboard makes the contrast between endpoints immediately visible. The endpoint doing the most work registers significantly more CPU time per request, and that ratio shows up directly in its CO2e share. For a service processing millions of requests per day, the difference compounds fast. Swapping an inefficient algorithm for a better one cuts the energy footprint measurably, and the improvement appears in the dashboard within seconds of redeployment.

The examples directory [11] also contains a Quarkus REST service with its own pre-built dashboard, and plain JDK examples for both JDK 21 and JDK 8 — making it straightforward to try the tooling on legacy applications that have not migrated to a modern framework.

## Accuracy — Honest Numbers

The FSE 2025 study [7] measured accuracy as the ratio of OTJAE's power estimate to direct RAPL hardware readings — in other words, how much of the real measured power the model actually accounts for. The pattern is consistent: the higher the load, the closer the estimate. At around 50% CPU utilisation the model accounts for roughly 75% of measured power; by the time the CPU is near full load it reaches above 98%. Below 30% utilisation the model accounts for only around 60%, because server hardware does not follow a linear power curve at low load. Storage controllers, NICs, and the BMC (Baseboard Management Controller) all draw significant fixed power that a CPU-proportional model systematically underestimates.

**Practical guideline**: below 30–40% sustained CPU utilisation, treat OTJAE numbers as a lower-bound estimate rather than an absolute figure. At medium-to-high load the model is production-grade.

## Known Limitations

**Reactive and virtual-thread workloads**: OTJAE measures resource demand per span by comparing thread-local readings at span start and end. If a span hops between threads, which is common in reactive frameworks like Project Reactor [13] or RxJava [14] and possible with virtual threads under heavy continuation switching, the delta calculation is invalid. The extension detects this and excludes affected spans from metric aggregation; the raw span attributes are still attached for manual inspection. Memory demand cannot be captured for virtual threads at all due to JVM constraints. CPU demand falls back to the carrier thread, which may overestimate for workloads with many parked virtual threads.

**OS scope**: Disk and network demand require Linux with kernel ≥ 3.14. On macOS and Windows you get CPU and heap only.

**Overhead**: Two thread-local reads per span — one at start, one at end. Benchmarks on the Spring example application show added latency below 1% at typical load. Up-to-date figures are in the README [4].

## What to Try Next

Once the setup is running, a few experiments are worth doing immediately.

1. **Load test it** — the example application ships with an Apache JMeter [15] script. Run it and watch the dashboards update in real time. The numbers only get interesting under real load.

2. **Change the region** — switch `eu-central-1` (low-carbon grid) to a coal-heavy region and watch the CO2 estimate climb without touching any code. Watching a number respond to a single configuration switch makes the concept of grid carbon intensity click faster than any explanation.

3. **Add an energy budget to CI** — the OpenTelemetry metrics endpoint is standard. Fail the build if a key transaction's CPU demand per request crosses a threshold. Catching regressions in CI costs far less than investigating them in production.

4. **Play with hardware lifespan** — set `io.retit.emissions.hardware.lifespan` to 3 or 6 years to see how hardware refresh cycles move the embodied-emissions needle.

## Conclusion

For cloud environments where RAPL is inaccessible — which covers most production deployments — OTJAE is one of the most practical tools available today for per-transaction energy attribution. It requires no application code changes, integrates with the OpenTelemetry pipeline teams already operate, and produces numbers validated against hardware measurements in a peer-reviewed study.

Green software engineering starts with measurement. Now you have the tools.

---

*The source code, examples, and pre-built dashboards are available at github.com/RETIT/opentelemetry-javaagent-extension [4] under the Apache 2.0 license.*

---

### About the Author

Manuel Steinberg is a PhD candidate at Hochschule München (Munich University of Applied Sciences) researching green software metrics and measurement methodologies for accurately quantifying the energy footprint of software applications.

---

## References

[1] C. Freitag et al., "The real climate and transformative impact of ICT," *Patterns* 2(9), 2021. https://pmc.ncbi.nlm.nih.gov/articles/PMC8441580/

[2] IEA, "Aviation," *IEA Energy Systems*. https://www.iea.org/energy-system/transport/aviation

[3] EU, *Corporate Sustainability Reporting Directive* (2022/2464), *OJEU*, 2022. https://eur-lex.europa.eu/eli/dir/2022/2464/oj/eng

[4] RETIT, *opentelemetry-javaagent-extension* (Apache 2.0). https://github.com/RETIT/opentelemetry-javaagent-extension

[5] OpenTelemetry, *opentelemetry-java-instrumentation*. https://github.com/open-telemetry/opentelemetry-java-instrumentation

[6] Cloud Carbon Footprint, "Methodology," *CCF Docs*. https://www.cloudcarbonfootprint.org/docs/methodology/

[7] A. Brunnert, "Evaluating the accuracy of software energy consumption models for Java applications," *FSE 2025*. https://doi.org/10.1145/3696630.3728709

[8] Etsy Engineering, "Cloud Jewels: Estimating kWh in the cloud," *Code as Craft*. https://www.etsy.com/codeascraft/cloud-jewels-estimating-kwh-in-the-cloud

[9] SPEC, *SPECpower_ssj2008 Results*. https://www.spec.org/power_ssj2008/results/

[10] Umweltbundesamt, "CO2-Emissionen pro kWh Strom 2024." https://www.umweltbundesamt.de/themen/co2-emissionen-pro-kilowattstunde-strom-2024

[11] RETIT, *OTJAE examples*. https://github.com/RETIT/opentelemetry-javaagent-extension/tree/main/examples

[12] JoularJX Authors, *JoularJX: Java Energy Profiler*. https://github.com/joularjx/joularjx

[13] VMware, *Project Reactor*. https://projectreactor.io/

[14] ReactiveX, *RxJava*. https://github.com/ReactiveX/RxJava

[15] Apache Software Foundation, *Apache JMeter*. https://jmeter.apache.org/

[16] Green Software Foundation, *Software Carbon Intensity (SCI) Specification* (ISO/IEC 21031:2024). https://greensoftware.foundation/projects/software-carbon-intensity
