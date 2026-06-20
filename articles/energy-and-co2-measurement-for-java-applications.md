# Estimating Energy Consumption and CO2 Emissions of Java Applications with OpenTelemetry

*How to turn any Java application into a green software observatory — without touching the code*

## Why Software Energy Consumption Matters

The IT industry accounts for roughly 2–4% of global greenhouse-gas emissions [1] — comparable to aviation [2]. Yet most teams optimise for throughput, latency, and reliability; energy efficiency rarely reaches the sprint board.

That is changing. EU sustainability regulations are tightening — most notably the Corporate Sustainability Reporting Directive (CSRD) [3] — and customers increasingly ask about the carbon footprint of their services. *"How much energy does the service consume?"* is becoming as commercially relevant as *"How fast does it respond?"*. The Green Software Foundation's **Software Carbon Intensity (SCI)** specification, now ISO/IEC 21031:2024 [4], standardises software emissions per functional unit of work. But software consumes no energy; the hardware it runs on does, and attributing that power to a specific Java application — or a single HTTP transaction — requires measurement and modelling.

Specialised tools like JoularJX [5] read Intel's RAPL interface, which reports actual socket-level energy consumption in real time. The catch: RAPL needs direct hardware access, which disappears the moment you deploy to AWS, Google Cloud, or Azure. Model-based tools instead estimate energy from metrics that *are* available in the cloud — CPU time, heap allocation, disk and network I/O — mapping them to power draw via known hardware profiles. The accuracy is not perfect at every load level, but it is good enough for production — with no specialised infrastructure, no root access, and no application changes.

This article walks through one such tool — the OpenTelemetry Java Agent Extension (OTJAE) — from zero to per-transaction CO2 estimates in minutes.

## What Is OTJAE

OTJAE [6] is an open-source add-on for the official OpenTelemetry Java auto-instrumentation agent [7], which is required for either integration option; if you already run it, OTJAE adds one flag or one dependency. It adds four resource-demand dimensions to every traced transaction:

| Dimension | Unit | Platform |
|-----------|------|----------|
| CPU time  | milliseconds | Linux, macOS, Windows |
| Heap allocation | bytes | Linux, macOS, Windows |
| Disk I/O (read + write) | bytes | Linux (kernel >= 3.14) |
| Network I/O (read + write) | bytes | Linux (kernel >= 3.14) |

All four feed an energy model with two outputs: **process-level** energy and CO2 (for cost attribution and reporting) and **per-transaction** energy and CO2 (for spotting which endpoints drive your power bill). The model follows the Cloud Carbon Footprint (CCF) [8] methodology, with pre-loaded coefficient tables for AWS, Azure, and GCP. On-premise hardware is supported too, via configurable CPU power, data-centre PUE (Power Usage Effectiveness, the ratio of total facility power to IT equipment power), and grid emissions factors.

A peer-reviewed study at FSE 2025 [9] validated OTJAE against direct Intel RAPL hardware measurements. RAPL gives accurate node-level totals but cannot attribute consumption to individual transactions — the gap OTJAE fills.

## How the Numbers Are Calculated

Knowing how the model works tells you when to trust its numbers.

![Per-transaction resource demand capture across applications](../img/extension_data_capture.png)

*Figure 1: OTJAE captures CPU, memory, storage, and network demand independently for every transaction across all instrumented applications.*

Each transaction receives a share of the server's power proportional to the CPU time it consumed. OTJAE uses the linear model from Etsy's *Cloud Jewels* [10], interpolating CPU power between idle and full load:

```
P_CPU = P_min + (CPU_utilisation x (P_max - P_min))
```

For a single transaction, utilisation comes from the thread's CPU-time delta across the span:

```
CPU_util_transaction = thread_cpu_time_ms / (CPU_cores x span_duration_ms)
```

Multiplying this share of power by the span's duration gives the transaction's energy. The same logic applies to memory, disk, and network, with heap allocation as a proxy for memory demand (it does not directly represent DRAM power). Carbon emissions are then energy times the region's grid factor (gCO2e/kWh), plus a pro-rated share of the hardware's embodied emissions — the cost of manufacturing it.

For cloud deployments, every coefficient — processor TDP (Thermal Design Power, rated max heat output at full load), memory power, embodied emissions, and regional grid factors — is pre-loaded from the CCF dataset. That is why provider, region, and instance type unlock the full picture: without them, the extension measures resource demand but has no power envelope to map it to.

## Instrumenting Your Application

Switching OTJAE on takes three things and no application-code changes: a way to load it, a backend to receive its data, and a cloud or hardware profile that turns demand into energy and CO2. This section covers each.

### Choosing an Integration Option

OTJAE offers two integration options, both requiring the OpenTelemetry Java agent:

| | Java Agent (Option A) | CDI Library (Option B) |
|---|---|---|
| Spring Boot | Recommended | Not applicable |
| Quarkus | Works | Preferred (requires GitHub Packages auth) |
| WildFly / Jakarta EE | Works | Preferred (requires GitHub Packages auth) |
| Plain JVM / legacy apps | Only option | Not applicable |

Option A loads OTJAE via a JVM flag and works wherever you control startup parameters. Option B uses CDI bean auto-discovery — cleaner for Quarkus and Jakarta EE, but requiring a one-time GitHub Packages authentication step.

Before picking an option, you need a backend. OTJAE emits standard OpenTelemetry signals, so any compatible backend works. If you don't have one, the repository includes a docker-compose stack with Prometheus, Grafana, and an OpenTelemetry Collector:

```bash
docker compose -f examples/docker/docker-compose.yml up -d
```

> **How the data flows**: The application pushes metrics via OTLP to the Collector (`localhost:4317`); Prometheus scrapes them from the Collector and never talks to the application directly. The stack is pre-configured, so the application only needs to target the Collector.

That same stack powers the Spring example later.

### Option A: JVM Flags (Spring Boot, Plain JVM, Legacy Apps)

This works with any JVM application where you control startup parameters: two JARs and a handful of flags.

#### Step 1 — Download the JARs

```bash
# OpenTelemetry Java Agent (base agent)
curl -L -o opentelemetry-javaagent.jar \
  https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar

# OpenTelemetry Java Agent Extension (OTJAE)
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

OTJAE is now active and capturing CPU and heap demand on every span. The OTel agent exports via OTLP to `http://localhost:4317` by default, matching the docker-compose stack above. For a different backend, add `-Dotel.exporter.otlp.endpoint=http://<your-collector>:4317`.

#### Step 3 — Add the cloud or hardware profile for emissions estimates

Without a cloud profile the extension captures resource demand but cannot convert it to energy or CO2. Add three system properties to the Step 2 command:

```bash
  -Dio.retit.emissions.cloud.provider=aws \
  -Dio.retit.emissions.cloud.provider.region=eu-central-1 \
  -Dio.retit.emissions.cloud.provider.instance.type=t3.medium \
```

The pattern is the same for GCP and Azure — swap `aws` for `gcp` or `azure` and adjust region and instance type. For on-premise hardware, replace the cloud properties with idle and peak CPU power (from SPECpower_ssj2008 [11]), a PUE for your data centre, and your country's grid emissions factor. Germany's 2024 factor [12] is roughly 363 g CO2e/kWh, down from 434 in 2022.

### Option B: Java Dependency (Quarkus and CDI Frameworks)

On a CDI-enabled framework such as Quarkus or WildFly, the latest release [6] lets you skip the JVM flags: add a dependency and CDI's bean auto-discovery wires up the span processor automatically.

One caveat: the CDI library is currently distributed via GitHub Packages, not Maven Central, so `mvn compile` will not work out of the box — you need a GitHub personal access token (PAT) and a one-time entry in `~/.m2/settings.xml`. The examples use Maven; Gradle projects consume the library from the same repository via standard configuration [6].

#### Step 1 — Authenticate with GitHub Packages

GitHub Packages requires a PAT with the `read:packages` scope, even for public repositories. Add your credentials to `~/.m2/settings.xml`:

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

Then declare the repository in your `pom.xml`:

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
  <version>0.1.0-beta</version>
</dependency>
```

For Quarkus, `quarkus-opentelemetry` must also be on the classpath — it provides the SDK the library hooks into and is usually already present in any Quarkus service that exports traces. CDI then registers the library's span processor (`RETITSpanProcessorConfiguration`) via its `META-INF/beans.xml`, with no additional wiring.

#### Step 3 — Configure via application.properties

The same OTJAE properties work in CDI mode, set through Quarkus's `application.properties`:

```properties
# OTLP exporter — point to your OpenTelemetry Collector
quarkus.otel.exporter.otlp.endpoint=http://localhost:4317

# OTJAE cloud profile
io.retit.emissions.cloud.provider=aws
io.retit.emissions.cloud.provider.region=eu-central-1
io.retit.emissions.cloud.provider.instance.type=t3.medium
```

Environment variables work too — replace dots with underscores and uppercase. A complete example lives in the examples directory [13].

## Configuration Reference

The three properties shown above — `io.retit.emissions.cloud.provider`, `.region`, and `.instance.type` — are the minimum needed for energy and CO2 figures. A few others are worth knowing: `io.retit.log.disk.demand` and `io.retit.log.network.demand` (both `false` by default) enable per-span disk and network I/O capture on Linux with kernel >= 3.14, and `io.retit.emissions.hardware.lifespan` (default `4` years) tunes the embodied-emissions share. The complete reference — CPU and memory capture toggles, the on-premise CPU-power, PUE and grid-factor overrides, and the full metric and span-attribute names — lives in the repository README [6].

## Reading the Metrics

OTJAE exports two categories of metric, and the distinction matters when building dashboards or alerts. **Resource demand counters** are cumulative per-instance totals (CPU time in ms, heap allocation, disk and network I/O in bytes) built for rate functions — `rate()` in PromQL gives the **process-level** view, and dividing by request rate gives the **per-transaction** view promised earlier. **Emissions configuration gauges** are published once at startup and stay static — idle and peak CPU power, grid emissions factor, PUE, and per-unit energy coefficients — and the pre-built dashboards use them to compute CO2e in Grafana, with no pre-aggregation in the JVM.

Every span additionally carries the same demand as **span attributes** (start and end readings), enabling trace-level profiling: open a slow request in any trace viewer, walk the span tree, and see how much CPU or heap each method call consumed. Full metric and attribute names are in the README [6].

## Seeing It in Practice

The repository ships with a ready-to-run Spring Boot example — the same application used in the FSE 2025 study [9]. It exposes three REST endpoints that differ in how much work they do:

```
GET    http://localhost:8081/test-rest-endpoint/getData
POST   http://localhost:8081/test-rest-endpoint/postData
DELETE http://localhost:8081/test-rest-endpoint/deleteData
```

The Maven build downloads and stages both agent JARs during `./mvnw clean package`, under `target/jib/otel/`. For your own application, use the JAR paths from Option A, Step 1.

```bash
# Build the project
./mvnw clean package -pl examples/spring-rest-service -am

# Start the backend (Prometheus + Grafana + OpenTelemetry Collector)
docker compose -f examples/docker/docker-compose.yml up -d

# Run the instrumented app (AWS eu-central-1, t3.medium)
java \
  -javaagent:examples/spring-rest-service/target/jib/otel/opentelemetry-javaagent.jar \
  -Dotel.service.name=spring-app \
  -Dotel.javaagent.extensions=examples/spring-rest-service/target/jib/otel/io.retit.opentelemetry.javaagent.extension.jar \
  -Dio.retit.emissions.cloud.provider=aws \
  -Dio.retit.emissions.cloud.provider.region=eu-central-1 \
  -Dio.retit.emissions.cloud.provider.instance.type=t3.medium \
  -jar examples/spring-rest-service/target/spring-rest-service.jar
```

Open `http://localhost:3000/grafana/dashboards` for live resource demand and emissions data. Grafana sits at the `/grafana` subpath, not the root (the stack sets `GF_SERVER_ROOT_URL`), so `http://localhost:3000` returns a blank page.

![Spring REST service Grafana dashboard showing SCI CO2eq per transaction, CPU demand, and emission calculation factors](../img/spring_dashboard.png)

*Figure 2: The pre-built Spring dashboard shows SCI (Software Carbon Intensity) in gCO2eq for each transaction type, CPU demand per transaction and for the whole process, plus the emission calculation factors used.*

The real gain here is transparency: every endpoint now carries its own Software Carbon Intensity in gCO2eq per request — a number that was previously invisible. Carbon becomes a signal you can compare across endpoints and track over time, just like latency or throughput, and an optimisation shows up in the dashboard within minutes of redeployment.

The examples directory [13] also contains a Quarkus REST service with its own dashboard and plain-JDK examples for JDK 21 and JDK 8.

## Accuracy in Practice

The FSE 2025 study [9] measured accuracy as the ratio of OTJAE's estimate to direct RAPL readings — how much of the real measured power the model accounts for. The pattern is consistent: the higher the load, the closer the estimate. At around 50% CPU utilisation the model accounts for roughly 75% of measured power; near full load, above 98%. Below 30% it captures only around 60%, because server hardware does not follow a linear power curve at low load: storage controllers, NICs, and the BMC (Baseboard Management Controller) draw significant fixed power that a CPU-proportional model underestimates.

**Practical guideline**: below 30–40% sustained CPU utilisation, treat OTJAE numbers as a lower bound, not an absolute figure. At medium-to-high utilisation, they are accurate enough for most operational and optimisation work.

## Known Limitations

**OS scope**: Disk and network demand require Linux with kernel >= 3.14; on macOS and Windows you get CPU and heap only. Containers may expose host-level rather than container-local I/O counters, depending on runtime configuration.

**Threading**: Resource-demand values are only valid when the thread that starts a span is the one that ends it. For reactive frameworks and virtual threads, where work can migrate between threads, OTJAE still attaches span attributes but does not publish metrics it cannot attribute reliably.

**Overhead**: OTJAE performs two thread-local reads per span (start and end). Benchmarks on the Spring example show added latency below 1% at typical load; up-to-date figures are in the README [6].

## What to Try Next

With the setup running, a few experiments are worth doing.

1. **Load test it** — the example ships with an Apache JMeter [14] script. Run it and watch the dashboards update in real time; the numbers are only meaningful under load.

2. **Change the region** — switch `eu-central-1` (low-carbon grid) to a coal-heavy region and watch the CO2 estimate climb without touching any code.

3. **Add an energy budget to CI** — use the OpenTelemetry metrics endpoint to fail the build if a key transaction's CPU demand per request crosses a threshold.

4. **Play with hardware lifespan** — set `io.retit.emissions.hardware.lifespan` to 3 or 6 years to see how refresh cycles shift the embodied-emissions share.

## Conclusion

RAPL and OTJAE solve different problems. RAPL gives accurate node-level totals; OTJAE attributes consumption to individual transactions across any deployment, including clouds where RAPL is unavailable. It needs no code changes, integrates with an OpenTelemetry pipeline teams may already run, and produces numbers validated against hardware in a peer-reviewed study.

Green software engineering starts with measurement. Now you have the tools to do it.

---

*The source code, examples, and pre-built dashboards are available at github.com/RETIT/opentelemetry-javaagent-extension [6] under the Apache 2.0 license.*

---

### About the Author

Manuel Steinberg is a PhD candidate at Hochschule München (Munich University of Applied Sciences) researching green software metrics and measurement methodologies for accurately quantifying the energy footprint of software applications.

---

## References

[1] C. Freitag et al., "The real climate and transformative impact of ICT," *Patterns* 2(9), 2021. https://pmc.ncbi.nlm.nih.gov/articles/PMC8441580/

[2] IEA, "Aviation," *IEA Energy Systems*. https://www.iea.org/energy-system/transport/aviation

[3] EU, *Corporate Sustainability Reporting Directive* (2022/2464), *OJEU*, 2022. https://eur-lex.europa.eu/eli/dir/2022/2464/oj/eng

[4] Green Software Foundation, *Software Carbon Intensity (SCI) Specification* (ISO/IEC 21031:2024). https://greensoftware.foundation/projects/software-carbon-intensity

[5] JoularJX Authors, *JoularJX: Java Energy Profiler*. https://github.com/joularjx/joularjx

[6] RETIT, *opentelemetry-javaagent-extension* (Apache 2.0). https://github.com/RETIT/opentelemetry-javaagent-extension

[7] OpenTelemetry, *opentelemetry-java-instrumentation*. https://github.com/open-telemetry/opentelemetry-java-instrumentation

[8] Cloud Carbon Footprint, "Methodology," *CCF Docs*. https://www.cloudcarbonfootprint.org/docs/methodology/

[9] A. Brunnert, "Evaluating the Accuracy of Software Energy Consumption Models for Java Applications at Process and Transaction Levels," *FSE Companion '25 (DevOpsSustain Workshop)*, Trondheim, 2025. https://doi.org/10.1145/3696630.3728709

[10] Etsy Engineering, "Cloud Jewels: Estimating kWh in the cloud," *Code as Craft*. https://www.etsy.com/codeascraft/cloud-jewels-estimating-kwh-in-the-cloud

[11] SPEC, *SPECpower_ssj2008 Results*. https://www.spec.org/power_ssj2008/results/

[12] Umweltbundesamt, "CO2-Emissionen pro kWh Strom 2024." https://www.umweltbundesamt.de/themen/co2-emissionen-pro-kilowattstunde-strom-2024

[13] RETIT, *OTJAE examples*. https://github.com/RETIT/opentelemetry-javaagent-extension/tree/main/examples

[14] Apache Software Foundation, *Apache JMeter*. https://jmeter.apache.org/
