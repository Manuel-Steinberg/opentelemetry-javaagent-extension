# Estimating Energy Consumption and CO2eq Emissions of Java Applications with OpenTelemetry

## Why software energy consumption matters

The ICT sector accounts for somewhere between 2 and 4 percent of global greenhouse gas emissions, depending on how far up the supply chain you count [1], which is comparable to aviation [2]. EU sustainability regulations are tightening, most notably the Corporate Sustainability Reporting Directive (CSRD) [3], and customers ask about the carbon footprint of their services. The Green Software Foundation's **Software Carbon Intensity (SCI)** specification, now ISO/IEC 21031:2024 [4], standardizes software emissions per functional unit of work. Attributing energy consumption to a specific Java application or a single HTTP transaction requires measurement and modeling.

Specialized tools like JoularJX [5] read Intel's RAPL interface, which reports socket-level energy consumption from on-chip counters, sampled at short intervals [15]. RAPL is itself model-based on several processor generations, but it is the closest thing to a hardware reference a server offers. It requires direct hardware access, which is heavily limited on virtualized cloud instances, e.g., AWS, Google Cloud or Azure. Model-based tools instead estimate energy from metrics that *are* available in the cloud, such as CPU time, heap allocation, disk and network I/O, and map them to power draw using published power data for the underlying hardware. The approach needs no specialized infrastructure, no root access, and no application-code changes.

Following I am going to show how OTJAE produces per-transaction CO2eq estimates.

## What is OTJAE

The OpenTelemetry Java Agent Extension (OTJAE) [6] is an open-source extension for the official OpenTelemetry Java auto-instrumentation agent [7]. If you already use OpenTelemetry, adding OTJAE only requires one JVM flag or dependency. It captures four resource-demand signals for every traced transaction, two of them on by default and two opt-in:

| Dimension | Unit | Platform |
|-----------|------|----------|
| CPU time  | milliseconds | Linux, macOS, Windows |
| Heap allocation | bytes | Linux, macOS, Windows |
| Disk I/O (read + write) | bytes | Linux (kernel >= 3.14; opt-in) |
| Network I/O (read + write) | bytes | Linux (kernel >= 3.14; opt-in) |

These signals feed an energy model that turns resource demand into hardware power, power into energy, and energy into CO2eq. It has two outputs: **process-level** energy and CO2eq for the whole application, and **per-transaction** energy and CO2eq for identifying which endpoints emit the most. The model follows the Cloud Carbon Footprint (CCF) methodology [8] and covers cloud instances on AWS, Azure, and GCP as well as on-premise hardware, the latter through configurable CPU power, data-center PUE (Power Usage Effectiveness, the ratio of total facility power to IT equipment power), and grid emissions factors.

## How the numbers are calculated

![Per-transaction resource demand capture across applications](../img/extension_data_capture.png)

The CCF methodology turns the captured resource demand into power, as described and evaluated in the underlying papers [9, 14]. For CPU, it derives a processor's power from its current CPU utilization and the processor's idle and maximum power. That power is attributed to the running process according to its share of overall system CPU utilization, and then to an individual transaction according to that transaction's share of the process's CPU demand. A similar approach applies to memory, storage, and network demand.

Multiplying the attributed power by time gives energy. The model converts that energy to emissions using the region's grid emission factor (in gCO2eq/kWh) and adds a pro-rated share of the hardware's embodied emissions, the carbon released when the hardware was manufactured.

For cloud deployments, all of these values are pre-loaded from the CCF dataset: the processor's idle and maximum power, memory power, embodied emissions, and regional grid factors.

## Instrumenting your application

### Choosing an integration option

OTJAE offers two integration options:

| | Java Agent (Option A) | CDI Library (Option B) |
|---|---|---|
| Spring Boot | Yes, and the only option | Not applicable |
| Quarkus | Yes | Preferred (requires GitHub Packages auth) |
| Jakarta EE | Yes | Preferred (requires GitHub Packages auth) |
| Plain JVM | Yes, and the only option | Not applicable |

Option A loads OTJAE via a JVM flag and works wherever you control startup parameters. Option B uses CDI bean auto-discovery. It is cleaner for Quarkus and Jakarta EE but requires a one-time GitHub Packages authentication step.

Whichever option you pick, you need a backend. OTJAE emits standard OpenTelemetry signals, so any compatible backend works. If you don't have one, the repository [6] ships a docker-compose stack with Prometheus, Grafana, and an OpenTelemetry Collector; the command to start it is in *Seeing it in practice* below.

### Option A: JVM flags (Spring Boot, plain JVM)

#### Step 1: Download the JARs

```bash
# OpenTelemetry Java Agent
curl -L -o opentelemetry-javaagent.jar \
  https://github.com/open-telemetry/opentelemetry-java-instrumentation/\
releases/latest/download/opentelemetry-javaagent.jar

# OpenTelemetry Java Agent Extension (OTJAE)
curl -L -o io.retit.opentelemetry.javaagent.extension.jar \
  https://github.com/RETIT/opentelemetry-javaagent-extension/releases/latest/\
download/io.retit.opentelemetry.javaagent.extension.jar
```

#### Step 2: Start your application with the agent

```bash
java \
  -javaagent:./opentelemetry-javaagent.jar \
  -Dotel.javaagent.extensions=./io.retit.opentelemetry.javaagent.extension.jar \
  -Dotel.service.name=your-service \
  -jar ./your-application.jar
```

OTJAE is now active and capturing CPU and heap demand on every span; disk and network capture are added in Step 3. The OpenTelemetry agent exports via OTLP to `http://localhost:4317` by default, matching the docker-compose stack from the repository. For a different backend, add `-Dotel.exporter.otlp.endpoint=http://<your-collector>:4317`.

#### Step 3: Add the cloud or hardware profile for emissions estimates

Without a cloud profile the extension captures resource demand but cannot convert it to energy or CO2eq. Add these three system properties to the Step 2 command, ahead of `-jar`:

```bash
  -Dio.retit.emissions.cloud.provider=aws \
  -Dio.retit.emissions.cloud.provider.region=eu-central-1 \
  -Dio.retit.emissions.cloud.provider.instance.type=t3.medium \
```

On Linux, two more properties switch on the opt-in signals:

```bash
  -Dio.retit.log.disk.demand=true \
  -Dio.retit.log.network.demand=true \
```

For GCP or Azure, swap `aws` for `gcp` or `azure` and adjust region and instance type. For on-premise hardware, set `io.retit.emissions.cloud.provider=OnPremise` and supply idle and peak CPU power (from SPECpower_ssj2008 [10]), a PUE for your data center, your country's grid emissions factor, and the hardware's embodied emissions. Germany's 2024 factor [11] is roughly 363 g CO2eq/kWh, down from 433 in 2022; the extension's on-premise default is 342 g CO2eq/kWh, an ElectricityMaps figure for 2025, so pick whichever matches your reporting basis.

Watch the on-premise embodied-emissions default in particular: it is zero, so manufacturing carbon is silently missing from your numbers until you set it from your vendor or from Boavizta [16]. Cloud instances get theirs pre-loaded.

### Option B: Java dependency (Quarkus and CDI frameworks)

On a CDI-enabled framework such as Quarkus, the latest release [6] lets you skip the JVM flags: add a dependency and CDI's bean auto-discovery wires up the span processor automatically.

The CDI library is currently distributed via GitHub Packages, not Maven Central, so `mvn compile` will not work out of the box. You need a GitHub personal access token (PAT) and a one-time entry in `~/.m2/settings.xml`. Gradle projects need the equivalent GitHub Packages repository and credentials.

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
    <url>
      https://maven.pkg.github.com/RETIT/opentelemetry-javaagent-extension
    </url>
  </repository>
</repositories>
```

#### Step 2: Add the dependency

```xml
<dependency>
  <groupId>io.retit</groupId>
  <artifactId>opentelemetry-java-agent-extension-cdi-library</artifactId>
  <version>0.1.3-beta</version>
</dependency>
```

For Quarkus, `quarkus-opentelemetry` must also be on the classpath. It provides the SDK the library hooks into and is usually already present in any Quarkus service that exports traces.

#### Step 3: Configure via application.properties

The same OTJAE properties work in CDI mode, set through Quarkus's `application.properties`:

```properties
# OTLP exporter: point to your OpenTelemetry Collector
quarkus.otel.exporter.otlp.endpoint=http://localhost:4317

# OTJAE cloud profile
io.retit.emissions.cloud.provider=aws
io.retit.emissions.cloud.provider.region=eu-central-1
io.retit.emissions.cloud.provider.instance.type=t3.medium
```

Environment variables work too. Replace dots with underscores and use uppercase. A complete example lives in the examples directory [12].

## Seeing it in practice

The repository [6] includes a ready-to-run Spring Boot example, the same application used in the validation study [9]. It exposes `GET /getData`, `POST /postData` and `DELETE /deleteData` under `http://localhost:8081/test-rest-endpoint/`, three endpoints that differ in how much work they do. Building it needs JDK 21 or newer, and the backend stack needs a running Docker daemon. The Maven build stages both agent JARs under `target/jib/otel/`; for your own application, use the JAR paths from Option A, Step 1.

```bash
# Build the project (jib.skip skips the container build, which needs a running Docker daemon)
./mvnw clean package -pl extension,examples/spring-rest-service -am -Djib.skip=true -DskipTests

# Start the backend (Prometheus + Grafana + OpenTelemetry Collector)
docker compose -f examples/docker/docker-compose.yml up -d

# Run the instrumented app (AWS eu-central-1, t3.medium)
cd examples/spring-rest-service/target
java -javaagent:jib/otel/opentelemetry-javaagent.jar \
  -Dotel.javaagent.extensions=jib/otel/io.retit.opentelemetry.javaagent.extension.jar \
  -Dotel.service.name=spring-app \
  -Dio.retit.emissions.cloud.provider=aws \
  -Dio.retit.emissions.cloud.provider.region=eu-central-1 \
  -Dio.retit.emissions.cloud.provider.instance.type=t3.medium \
  -jar spring-rest-service.jar
```

An idle app leaves the dashboards empty. The following loop sends requests to all three endpoints for 15 minutes. It is the exact load behind Figure 2, so you can reproduce the figure yourself.

```bash
BASE=http://localhost:8081/test-rest-endpoint
end=$((SECONDS+900))   # run for 15 minutes
while [ $SECONDS -lt $end ]; do
  curl -s "$BASE/getData" -o /dev/null
  curl -s -X POST "$BASE/postData" -o /dev/null
  curl -s -X DELETE "$BASE/deleteData" -o /dev/null
done
```

Open `http://localhost:3000/grafana/dashboards`. Grafana is served from the `/grafana` sub-path, so the bare `http://localhost:3000` returns a blank page.

![The pre-built Spring dashboard (OTJAE v0.1.3-beta, cloud profile AWS t3.medium in eu-central-1, a ten-minute window of the 15-minute load loop above): SCI in gCO2eq per transaction type, CPU demand per transaction and for the whole process, and the emission factors behind them.](spring_dashboard_v0.1.3_light.png)

Every endpoint now carries its own Software Carbon Intensity, an SCI whose functional unit R is one request, in gCO2eq. The examples directory [12] also holds a Quarkus REST service with its own dashboard, plus plain-JDK examples for JDK 21 and JDK 8.

## Reading the metrics

**Resource demand counters** capture CPU time in milliseconds and heap, disk, and network I/O in bytes. OTJAE records them per transaction, tagged with the transaction's span attributes, so the resource demand of each transaction is available directly as a metric. The four counters are `io.retit.resource.demand.cpu.ms`, `.memory.bytes`, `.storage.bytes` and `.network.bytes`; process-wide CPU time is published separately as `io.retit.emissions.java.process.cpu.time`. In Prometheus, the first one is queried as `io_retit_resource_demand_cpu_ms_milliseconds_total`. In PromQL, `rate()` turns the cumulative counters into a per-second view.

OTJAE is built for **synchronous request processing**: resource-demand values are only valid when the thread that starts a span is the one that ends it. For reactive frameworks and virtual threads, where work can migrate between threads, OTJAE still attaches span attributes but does not publish metrics it cannot attribute reliably.

**Emissions configuration gauges** carry the model's constants: idle and peak CPU power, the instance's vCPU count, grid emissions factor, PUE, and embodied emissions. The pre-built dashboards use them to compute CO2eq directly in Grafana, with no pre-aggregation inside the JVM.

Every span additionally carries the same demand as **span attributes**, enabling trace-level profiling: open a slow request in any trace viewer, walk the span tree, and see how much CPU or heap each operation in the chain consumed. Full metric and attribute names are in the README [6].

## Accuracy in practice

A peer-reviewed study presented at the DevOpsSustain 2025 workshop [9] compared OTJAE's process-level estimate against RAPL readings on a bare-metal Xeon server (OTJAE v0.0.15-alpha). The higher the load, the better the results. At 53 percent CPU utilization, for example, OTJAE's estimate reached 76 percent of the RAPL-measured power.

The gap at low load is expected: power does not scale linearly with utilization, and the baseline draw of a mostly idle machine is not caused by your application. Note what was checked: the CPU model, at process level, on bare metal. The memory, storage, and network models, and the virtualized environments OTJAE is built for, have not been validated this way.

OTJAE reads resource-demand values twice per span, at start and at end. In the validation study [9] that cost nothing measurable: across three load levels, CPU utilization stayed within 1.5 percentage points and system power within about 1 W of the uninstrumented baseline.

**Practical guideline**: below roughly 30 percent sustained CPU utilization, treat OTJAE numbers as a lower bound rather than an absolute figure. Above that, they are accurate enough for comparing endpoints and tracking changes over time.

## What to try next

1. **Load test it**. The example ships an Apache JMeter [13] plan at `examples/spring-rest-service/src/test/resources/jmeter_testplan.jmx`. Run it and watch the dashboards update in real time. The numbers are most meaningful under load.

2. **Change the region**. For instance, swap `eu-central-1` for `eu-north-1`. The grid emission factor gauge then shows the factor the model is using: 0.338 kg CO2eq/kWh for Frankfurt against 0.008 for Stockholm, both from the CCF dataset.

3. **Add an energy budget to CI**. Use the OpenTelemetry metrics endpoint to fail the build if a key transaction's CPU demand per request crosses a threshold.

## Conclusion

OTJAE solves the issue that RAPL is limited on virtualized cloud instances. It attributes consumption to individual transactions on any infrastructure, needs no code changes, and integrates with an OpenTelemetry pipeline teams may already run.

*The source code, examples, and pre-built dashboards are available at github.com/RETIT/opentelemetry-javaagent-extension [6] under the Apache 2.0 license.*

### About the author

Manuel Steinberg is a PhD candidate at Hochschule München (Munich University of Applied Sciences). His research focuses on measuring the energy footprint of software applications.

*Disclosure: the validation study [9] and the earlier SSP paper [14] come from the same research group; OTJAE is developed by RETIT.*

## References

[1] <https://pmc.ncbi.nlm.nih.gov/articles/PMC8441580/>

[2] <https://www.iea.org/energy-system/transport/aviation>

[3] <https://eur-lex.europa.eu/eli/dir/2022/2464/oj/eng>

[4] <https://sci.greensoftware.foundation/> · <https://www.iso.org/standard/86612.html>

[5] <https://github.com/joular/joularjx>

[6] <https://github.com/RETIT/opentelemetry-javaagent-extension>

[7] <https://github.com/open-telemetry/opentelemetry-java-instrumentation>

[8] <https://www.cloudcarbonfootprint.org/docs/methodology/>

[9] <https://doi.org/10.1145/3696630.3728709>

[10] <https://www.spec.org/power_ssj2008/results/>

[11] <https://www.umweltbundesamt.de/themen/co2-emissionen-pro-kilowattstunde-strom-2024>

[12] <https://github.com/RETIT/opentelemetry-javaagent-extension/tree/main/examples>

[13] <https://jmeter.apache.org/>

[14] <https://dl.gi.de/items/3cbc03f9-64b5-41a8-be00-d45cea2412cb>

[15] <https://hotcarbon.org/assets/2026/paper-46.pdf>

[16] <https://dataviz.boavizta.org/>
