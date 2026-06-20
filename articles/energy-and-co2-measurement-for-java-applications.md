# Estimating Energy Consumption and CO2eq Emissions of Java Applications with OpenTelemetry

*How to turn any Java application into a green software observatory — without touching the code.*

## Why software energy consumption matters

The IT industry accounts for roughly 2 to 4 percent of global greenhouse gas emissions [1], which is comparable to aviation [2]. Yet most teams focus on throughput, latency, and reliability. Energy efficiency rarely reaches the sprint board.

That is changing. EU sustainability regulations are tightening, most notably the Corporate Sustainability Reporting Directive (CSRD) [3], and customers increasingly ask about the carbon footprint of their services. *"How much energy does the service consume?"* is becoming as commercially relevant as *"How fast does it respond?"*. The Green Software Foundation's **Software Carbon Intensity (SCI)** specification, now ISO/IEC 21031:2024 [4], standardises software emissions per functional unit of work. But software consumes no energy. The hardware it runs on does, and attributing that power to a specific Java application or a single HTTP transaction requires measurement and modelling.

Specialised tools like JoularJX [5] read Intel's RAPL interface, which reports actual socket-level energy consumption in real time. The catch: RAPL needs direct hardware access, which disappears the moment you deploy to AWS, Google Cloud, or Azure. Model-based tools instead estimate energy from metrics that *are* available in the cloud, such as CPU time, heap allocation, disk and network I/O, and map them to power draw using known hardware profiles. The accuracy is not perfect at every load level, but it is good enough for production use, with no specialised infrastructure, no root access, and no application changes!

This article walks through one such tool, the OpenTelemetry Java Agent Extension (OTJAE), from zero to per-transaction CO2eq estimates.

## What is OTJAE

OTJAE [6] is an open-source extension for the official OpenTelemetry Java auto-instrumentation agent [7]. If you already use OpenTelemetry, adding OTJAE only requires one JVM flag or dependency. It tracks four resource signals for every traced transaction:

| Dimension | Unit | Platform |
|-----------|------|----------|
| CPU time  | milliseconds | Linux, macOS, Windows |
| Heap allocation | bytes | Linux, macOS, Windows |
| Disk I/O (read + write) | bytes | Linux (kernel >= 3.14) |
| Network I/O (read + write) | bytes | Linux (kernel >= 3.14) |

All four feed an energy model with two outputs: **process-level** energy and CO2eq (for cost attribution and reporting) and **per-transaction** energy and CO2eq (for spotting which endpoints drive your power bill). The model follows the Cloud Carbon Footprint (CCF) [8] methodology, with pre-loaded coefficient tables for AWS, Azure, and GCP. On-premise hardware is supported too, via configurable CPU power, data-centre PUE (Power Usage Effectiveness, the ratio of total facility power to IT equipment power), and grid emissions factors.

A peer-reviewed study at FSE 2025 [9] validated OTJAE against direct Intel RAPL hardware measurements. RAPL gives accurate machine-level totals but cannot attribute consumption to individual transactions. OTJAE fills that gap.

## How the numbers are calculated

Knowing how the model works tells you when to trust its numbers.

![Per-transaction resource demand capture across applications](../img/extension_data_capture.png)

*Figure 1: OTJAE captures CPU, memory, storage, and network demand independently for every transaction across all instrumented applications.*

Each transaction receives a share of the server's power proportional to the CPU time it consumed. OTJAE uses the linear model from Etsy's *Cloud Jewels* [10], interpolating CPU power between idle and full load:

```
P_CPU = P_min + (CPU_utilisation x (P_max - P_min))
```

*(P_min and P_max are VM-instance-level values from the CCF dataset. Idle power is distributed proportionally across transactions rather than counted once per transaction.)*

For a single transaction, utilisation comes from the thread's CPU-time delta across the span:

```
CPU_util_transaction = thread_cpu_time_ms / (CPU_cores x span_duration_ms)
```

Multiplying this share of power by the span's duration gives the transaction's energy. The same logic applies to memory, disk, and network, with heap allocation as a proxy for memory demand (it does not directly represent DRAM power). Carbon emissions are then energy times the region's grid emission factor (gCO2eq/kWh), plus a pro-rated share of the hardware's embodied emissions, which represents the carbon cost of manufacturing the hardware.

For cloud deployments, all coefficients are pre-loaded from the CCF dataset. These include the processor TDP (Thermal Design Power, the rated maximum heat output at full load), memory power, embodied emissions, and regional grid factors. Provider, region, and instance type are needed to unlock the full picture. Without them, the extension measures resource demand but has no power envelope to map it to.

## Instrumenting your application

Switching OTJAE on takes three things and no application-code changes: a way to load it, a backend to receive its data, and a cloud or hardware profile that turns demand into energy and CO2eq. This section covers each.

### Choosing an integration option

OTJAE offers two integration options, both requiring the OpenTelemetry Java agent:

| | Java Agent (Option A) | CDI Library (Option B) |
|---|---|---|
| Spring Boot | Recommended | Not applicable |
| Quarkus | Works | Preferred (requires GitHub Packages auth) |
| WildFly / Jakarta EE | Works | Preferred (requires GitHub Packages auth) |
| Plain JVM / legacy apps | Recommended | Not applicable |

Option A loads OTJAE via a JVM flag and works wherever you control startup parameters. Option B uses CDI bean auto-discovery. It is cleaner for Quarkus and Jakarta EE but requires a one-time GitHub Packages authentication step.

Before picking an option, you need a backend. OTJAE emits standard OpenTelemetry signals, so any compatible backend works. If you don't have one, the repository includes a docker-compose stack with Prometheus, Grafana, and an OpenTelemetry Collector:

```bash
docker compose -f examples/docker/docker-compose.yml up -d
```

### Option A: JVM flags (Spring Boot, plain JVM, legacy apps)

This works with any JVM application where you control startup parameters: two JARs and a handful of flags.

#### Step 1: Download the JARs

```bash
# OpenTelemetry Java Agent
curl -L -o opentelemetry-javaagent.jar \
  https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar

# OpenTelemetry Java Agent Extension (OTJAE)
curl -L -o io.retit.opentelemetry.javaagent.extension.jar \
  https://github.com/RETIT/opentelemetry-javaagent-extension/releases/latest/download/io.retit.opentelemetry.javaagent.extension.jar
```

#### Step 2: Start your application with the agent

```bash
java \
  -javaagent:./opentelemetry-javaagent.jar \
  -Dotel.javaagent.extensions=./io.retit.opentelemetry.javaagent.extension.jar \
  -Dotel.service.name=your-service \
  -jar ./your-application.jar
```

OTJAE is now active and capturing CPU and heap demand on every span. The OpenTelemetry agent exports via OTLP to `http://localhost:4317` by default, matching the docker-compose stack above. For a different backend, add `-Dotel.exporter.otlp.endpoint=http://<your-collector>:4317`.

#### Step 3: Add the cloud or hardware profile for emissions estimates

Without a cloud profile the extension captures resource demand but cannot convert it to energy or CO2eq. Add three system properties to the Step 2 command:

```bash
  -Dio.retit.emissions.cloud.provider=aws \
  -Dio.retit.emissions.cloud.provider.region=eu-central-1 \
  -Dio.retit.emissions.cloud.provider.instance.type=t3.medium \
```

For GCP or Azure, swap `aws` for `gcp` or `azure` and adjust region and instance type. For on-premise hardware, replace the cloud properties with idle and peak CPU power (from SPECpower_ssj2008 [11]), a PUE for your data centre, and your country's grid emissions factor. Germany's 2024 factor [12] is roughly 363 g CO2eq/kWh, down from 434 in 2022.

### Option B: Java dependency (Quarkus and CDI frameworks)

On a CDI-enabled framework such as Quarkus or WildFly, the latest release [6] lets you skip the JVM flags: add a dependency and CDI's bean auto-discovery wires up the span processor automatically.

One caveat: the CDI library is currently distributed via GitHub Packages, not Maven Central, so `mvn compile` will not work out of the box. You need a GitHub personal access token (PAT) and a one-time entry in `~/.m2/settings.xml`. The examples use Maven. Gradle projects consume the library from the same repository via standard configuration [6].

#### Step 1: Authenticate with GitHub Packages

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

#### Step 2: Add the dependency

```xml
<dependency>
  <groupId>io.retit</groupId>
  <artifactId>opentelemetry-java-agent-extension-cdi-library</artifactId>
  <version>0.1.0-beta</version>
</dependency>
```

For Quarkus, `quarkus-opentelemetry` must also be on the classpath. It provides the SDK the library hooks into and is usually already present in any Quarkus service that exports traces. CDI then registers the library's span processor (`RETITSpanProcessorConfiguration`) via its `META-INF/beans.xml`, with no additional wiring.

#### Step 3: Configure via application.properties

The same OTJAE properties work in CDI mode, set through Quarkus's `application.properties`:

```properties
# OTLP exporter — point to your OpenTelemetry Collector
quarkus.otel.exporter.otlp.endpoint=http://localhost:4317

# OTJAE cloud profile
io.retit.emissions.cloud.provider=aws
io.retit.emissions.cloud.provider.region=eu-central-1
io.retit.emissions.cloud.provider.instance.type=t3.medium
```

Environment variables work too. Replace dots with underscores and use uppercase. A complete example lives in the examples directory [13].

## Reading the metrics

OTJAE exports two categories of metrics, and the distinction matters when building dashboards or alerts.

**Resource demand counters** are cumulative totals per instance. They cover CPU time in milliseconds, heap allocation, and disk and network I/O in bytes. Apply the `rate()` function in PromQL to get a process-level view per second. Divide by request rate to get the per-transaction view.

**Emissions configuration gauges** are published once at startup and remain fixed. They include idle and peak CPU power, grid emissions factor, PUE, and per-unit energy coefficients. The pre-built dashboards use them to compute CO2eq directly in Grafana, with no pre-aggregation inside the JVM.

Every span additionally carries the same demand as **span attributes** (start and end readings), enabling trace-level profiling: open a slow request in any trace viewer, walk the span tree, and see how much CPU or heap each method call consumed. Full metric and attribute names are in the README [6].

## Seeing it in practice

The repository includes a ready-to-run Spring Boot example. It is the same application used in the FSE 2025 study [9]. It exposes three REST endpoints that differ in how much work they do:

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

Every endpoint now carries its own Software Carbon Intensity in gCO2eq per request, a number that was previously invisible. Carbon becomes a signal you can compare across endpoints and track over time, just like latency or throughput. An improvement shows up in the dashboard within minutes of redeployment.

The examples directory [13] also contains a Quarkus REST service with its own dashboard and plain-JDK examples for JDK 21 and JDK 8.

## Accuracy in practice

The FSE 2025 study [9] measured accuracy by comparing OTJAE estimates to direct RAPL readings. The pattern is clear: the higher the load, the closer the estimate. At around 50 percent CPU load, the model accounts for roughly 75 percent of measured power. Near full load, it covers above 98 percent. Below 30 percent it captures only around 60 percent, because server hardware does not follow a linear power curve at low load. Components like storage controllers, network cards, and the baseboard management controller (BMC) draw significant fixed power that a CPU-proportional model underestimates.

**Practical guideline**: below 30–40% sustained CPU utilisation, treat OTJAE numbers as a lower bound, not an absolute figure. At medium-to-high utilisation, they are accurate enough for most operational and optimisation work.

## Known limitations

**OS scope**: Disk and network demand require Linux with kernel 3.14 or newer. On macOS and Windows you get CPU and heap only. Containers may expose host-level rather than container-local I/O counters, depending on runtime configuration.

**Threading**: Resource-demand values are only valid when the thread that starts a span is the one that ends it. For reactive frameworks and virtual threads, where work can migrate between threads, OTJAE still attaches span attributes but does not publish metrics it cannot attribute reliably.

**Overhead**: OTJAE performs two thread-local reads per span, one at start and one at end. Benchmarks on the Spring example show added latency below 1 percent at typical load. Up-to-date figures are in the README [6].

## What to try next

With the setup running, a few experiments are worth doing.

1. **Load test it**. The example includes an Apache JMeter [14] script. Run it and watch the dashboards update in real time. The numbers are most meaningful under load.

2. **Change the region**. Switch `eu-central-1` (low-carbon grid) to a coal-heavy region and watch the CO2eq estimate climb without touching any code.

3. **Add an energy budget to CI**. Use the OpenTelemetry metrics endpoint to fail the build if a key transaction's CPU demand per request crosses a threshold.

## Conclusion

RAPL and OTJAE solve different problems. RAPL gives accurate machine-level energy values. OTJAE attributes consumption to individual transactions across any deployment, including clouds where RAPL is unavailable. It needs no code changes, integrates with an OpenTelemetry pipeline teams may already run, and produces numbers validated against hardware in a peer-reviewed study.

Green software engineering starts with measurement. Now you have the tools to do it too.

*The source code, examples, and pre-built dashboards are available at github.com/RETIT/opentelemetry-javaagent-extension [6] under the Apache 2.0 license.*

### About the author

Manuel Steinberg is a PhD candidate at Hochschule München (Munich University of Applied Sciences). His research focuses on measuring the energy footprint of software applications.

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

[12] Umweltbundesamt, "CO2eq-Emissionen pro kWh Strom 2024." https://www.umweltbundesamt.de/themen/CO2eq-emissionen-pro-kilowattstunde-strom-2024

[13] RETIT, *OTJAE examples*. https://github.com/RETIT/opentelemetry-javaagent-extension/tree/main/examples

[14] Apache Software Foundation, *Apache JMeter*. https://jmeter.apache.org/
