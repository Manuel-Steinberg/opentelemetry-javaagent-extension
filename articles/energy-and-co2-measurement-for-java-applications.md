# Estimating Energy Consumption and CO2eq Emissions of Java Applications with OpenTelemetry

*How to turn any Java application into a green software observatory — without touching the code.*

## Why software energy consumption matters

The ICT sector accounts for somewhere between 2 and 4 percent of global greenhouse gas emissions, depending on how far up the supply chain you count [1], which is comparable to aviation [2]. Yet energy efficiency rarely reaches the sprint board.

That is changing. EU sustainability regulations are tightening, most notably the Corporate Sustainability Reporting Directive (CSRD) [3], and customers increasingly ask about the carbon footprint of their services. The Green Software Foundation's **Software Carbon Intensity (SCI)** specification, now ISO/IEC 21031:2024 [4], standardises software emissions per functional unit of work. But software consumes no energy. The hardware it runs on does, and attributing that consumption to a specific Java application or a single HTTP transaction requires measurement and modelling.

Specialised tools like JoularJX [5] read Intel's RAPL interface, which reports socket-level energy consumption from on-chip counters, sampled at short intervals [16]. RAPL is itself model-based on several processor generations, but it is the closest thing to a hardware reference a server offers. The catch: it needs direct hardware access, which disappears on virtualised cloud instances, the normal case on AWS, Google Cloud, and Azure. Model-based tools instead estimate energy from metrics that *are* available in the cloud, such as CPU time, heap allocation, disk and network I/O, and map them to power draw using published power data for the underlying hardware. How closely such an estimate tracks the real power draw depends on how hard the machine is working. In exchange, the approach needs no specialised infrastructure, no root access, and no application-code changes.

This article walks through one such tool, the OpenTelemetry Java Agent Extension (OTJAE), from zero to per-transaction CO2eq estimates, and closes with what a peer-reviewed evaluation against Intel RAPL hardware measurements [9] says about how far to trust them.

## What is OTJAE

OTJAE [6] is an open-source extension for the official OpenTelemetry Java auto-instrumentation agent [7]. If you already use OpenTelemetry, adding OTJAE only requires one JVM flag or dependency. It captures four resource-demand signals for every traced transaction, two of them on by default and two opt-in:

| Dimension | Unit | Platform |
|-----------|------|----------|
| CPU time  | milliseconds | Linux, macOS, Windows |
| Heap allocation | bytes | Linux, macOS, Windows |
| Disk I/O (read + write) | bytes | Linux (kernel >= 3.14; opt-in) |
| Network I/O (read + write) | bytes | Linux (kernel >= 3.14; opt-in) |

These signals feed an energy model that turns resource demand into hardware power, power into energy, and energy into CO2eq. It has two outputs: **process-level** energy and CO2eq for the whole application, and **per-transaction** energy and CO2eq for identifying which endpoints emit the most. The model follows the Cloud Carbon Footprint (CCF) methodology [8] and covers cloud instances on AWS, Azure, and GCP as well as on-premise hardware, the latter through configurable CPU power, data-centre PUE (Power Usage Effectiveness, the ratio of total facility power to IT equipment power), and grid emissions factors.

## How the numbers are calculated

![Per-transaction resource demand capture across applications](../img/extension_data_capture.png)

*Figure 1: OTJAE captures CPU, memory, storage, and network demand independently for every transaction across all instrumented applications.*

The CCF methodology turns the captured resource demand into power, as described and evaluated in the underlying papers [9, 15]. For CPU, it applies the linear model from Etsy's *Cloud Jewels* [10], which derives a processor's power from its current CPU utilisation by interpolating between the processor's idle and maximum power (for example from SPECpower results [11]). That power is attributed to the running process according to its share of overall system CPU utilisation, and then to an individual transaction according to that transaction's share of the process's CPU demand. A similar approach applies to memory, storage, and network demand, with heap allocation used as a proxy for memory.

Multiplying the attributed power by time gives energy. The model converts that energy to emissions using the region's grid emission factor (in gCO2eq/kWh) and adds a pro-rated share of the hardware's embodied emissions, the carbon released when the hardware was manufactured.

For cloud deployments, all of these values are pre-loaded from the CCF dataset: the processor's idle and maximum power, memory power, embodied emissions, and regional grid factors. Without provider, region, and instance type, the extension still records resource demand but has no power model to map it onto.

## Instrumenting your application

Switching OTJAE on takes three things: a way to load it, a backend to receive its data, and a cloud or hardware profile that turns demand into energy and CO2eq.

### Choosing an integration option

OTJAE offers two integration options:

| | Java Agent (Option A) | CDI Library (Option B) |
|---|---|---|
| Spring Boot | Yes, and the only option | Not applicable |
| Quarkus | Yes | Preferred (requires GitHub Packages auth) |
| WildFly / Jakarta EE | Yes | Preferred (requires GitHub Packages auth) |
| Plain JVM / legacy apps | Yes, and the only option | Not applicable |

Option A loads OTJAE via a JVM flag and works wherever you control startup parameters. Option B uses CDI bean auto-discovery. It is cleaner for Quarkus and Jakarta EE but requires a one-time GitHub Packages authentication step.

Whichever option you pick, you need a backend. OTJAE emits standard OpenTelemetry signals, so any compatible backend works. If you don't have one, the repository [6] ships a docker-compose stack with Prometheus, Grafana, and an OpenTelemetry Collector; the command to start it is in *Seeing it in practice* below.

### Option A: JVM flags (Spring Boot, plain JVM, legacy apps)

Two JARs and a handful of flags.

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

For GCP or Azure, swap `aws` for `gcp` or `azure` and adjust region and instance type. For on-premise hardware, set `io.retit.emissions.cloud.provider=OnPremise` — that value is what activates the `...onpremise.*` properties — and supply idle and peak CPU power (from SPECpower_ssj2008 [11]), a PUE for your data centre, your country's grid emissions factor, and the hardware's embodied emissions. Germany's 2024 factor [12] is roughly 363 g CO2eq/kWh, down from 433 in 2022; the extension's on-premise default is 342 g CO2eq/kWh, an ElectricityMaps figure for 2025, so pick whichever matches your reporting basis.

Two further settings move the result more than their names suggest. `io.retit.emissions.hardware.lifespan` (default 4 years) scales embodied emissions linearly, and it applies to cloud and on-premise alike. The two `...onpremise.*.vcpu.count` properties decide how much of the machine is attributed to this workload; in cloud mode that split comes from the CCF dataset. Watch the on-premise embodied-emissions default in particular: it is zero, so manufacturing carbon is silently missing from your numbers until you set it from your vendor or from Boavizta [17]. Cloud instances get theirs pre-loaded.

### Option B: Java dependency (Quarkus and CDI frameworks)

On a CDI-enabled framework such as Quarkus or WildFly, the latest release [6] lets you skip the JVM flags: add a dependency and CDI's bean auto-discovery wires up the span processor automatically.

One caveat: the CDI library is currently distributed via GitHub Packages, not Maven Central, so `mvn compile` will not work out of the box. You need a GitHub personal access token (PAT) and a one-time entry in `~/.m2/settings.xml`. Gradle projects need the equivalent GitHub Packages repository and credentials.

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
  <version>0.1.1-beta</version>
</dependency>
```

For Quarkus, `quarkus-opentelemetry` must also be on the classpath. It provides the SDK the library hooks into and is usually already present in any Quarkus service that exports traces. Via its `META-INF/beans.xml`, CDI auto-discovers the library's `RETITSpanProcessorConfiguration` producer bean, which registers the `RETITSpanProcessor` into the OpenTelemetry SDK pipeline with no additional wiring.

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

## Seeing it in practice

The repository [6] includes a ready-to-run Spring Boot example, the same application used in the validation study [9]. It exposes `GET /getData`, `POST /postData` and `DELETE /deleteData` under `http://localhost:8081/test-rest-endpoint/`, three endpoints that differ in how much work they do. The Maven build stages both agent JARs under `target/jib/otel/`; for your own application, use the JAR paths from Option A, Step 1.

```bash
# Build the project (jib.skip skips the container build, which needs a running Docker daemon)
./mvnw clean package -pl examples/spring-rest-service -am -Djib.skip=true

# Start the backend (Prometheus + Grafana + OpenTelemetry Collector)
docker compose -f examples/docker/docker-compose.yml up -d

# Run the instrumented app (AWS eu-central-1, t3.medium)
APP=examples/spring-rest-service/target
java -javaagent:$APP/jib/otel/opentelemetry-javaagent.jar \
  -Dotel.javaagent.extensions=$APP/jib/otel/io.retit.opentelemetry.javaagent.extension.jar \
  -Dotel.service.name=spring-app \
  -Dio.retit.emissions.cloud.provider=aws \
  -Dio.retit.emissions.cloud.provider.region=eu-central-1 \
  -Dio.retit.emissions.cloud.provider.instance.type=t3.medium \
  -jar $APP/spring-rest-service.jar
```

Fire a few requests at the endpoints so there is something to see; an idle app leaves the dashboards empty.

```bash
BASE=http://localhost:8081/test-rest-endpoint
for i in $(seq 1 20); do
  curl -s "$BASE/getData" -o /dev/null
  curl -s -X POST "$BASE/postData" -o /dev/null
  curl -s -X DELETE "$BASE/deleteData" -o /dev/null
done
```

Open `http://localhost:3000/grafana/dashboards`. Grafana is served from the `/grafana` sub-path, so the bare `http://localhost:3000` returns a blank page.

![Spring REST service Grafana dashboard showing SCI CO2eq per transaction, CPU demand, and emission calculation factors](../img/spring_dashboard.png)

*Figure 2: The pre-built Spring dashboard: SCI in gCO2eq per transaction type, CPU demand per transaction and for the whole process, and the emission factors behind them.*

Every endpoint now carries its own Software Carbon Intensity, an SCI whose functional unit R is one request, in gCO2eq. Carbon becomes a signal you can compare across endpoints and track over time, just like latency or throughput. The examples directory [13] also holds a Quarkus REST service with its own dashboard, plus plain-JDK examples for JDK 21 and JDK 8.

## Reading the metrics

Behind those dashboards are two categories of metrics, and the distinction matters when building your own dashboards or alerts.

**Resource demand counters** capture CPU time in milliseconds and heap, disk, and network I/O in bytes. OTJAE records them per transaction, tagged with the transaction's span attributes, so the resource demand of each transaction is available directly as a metric. Process-wide CPU time is published as a separate metric, `io.retit.emissions.java.process.cpu.time`. In PromQL, `rate()` turns the cumulative counters into a per-second view.

**Emissions configuration gauges** carry the model's constants: idle and peak CPU power, grid emissions factor, PUE, and per-unit energy coefficients. They are re-exported on every collection interval, but their values are fixed at startup. The pre-built dashboards use them to compute CO2eq directly in Grafana, with no pre-aggregation inside the JVM.

Every span additionally carries the same demand as **span attributes** (start and end readings), enabling trace-level profiling: open a slow request in any trace viewer, walk the span tree, and see how much CPU or heap each operation in the chain consumed. Full metric and attribute names are in the README [6].

## Accuracy in practice

A peer-reviewed study presented at the DevOpsSustain 2025 workshop [9] compared OTJAE's process-level estimate against RAPL readings on a bare-metal Xeon server (OTJAE v0.0.15-alpha). The higher the load, the closer the estimate, and the model always errs on the low side:

| System CPU utilisation | OTJAE estimate as a share of RAPL-measured power |
|---|---|
| 25 % | 59 % |
| 53 % | 76 % |
| 80 % | 90 % |
| 98 % | 98 % |

The gap at low load is expected: power does not scale linearly with utilisation, and the baseline draw of a mostly idle machine is not caused by your application. Note what was checked, though — the CPU model, at process level, on bare metal. The memory, storage, and network models, and the virtualised environments OTJAE is built for, have not been validated this way. Where RAPL is readable it stays the better number: the same study measured JoularJX above 97 percent at every load level.

**Practical guideline**: below roughly 30 percent sustained CPU utilisation, treat OTJAE numbers as a lower bound rather than an absolute figure. Above that, they are accurate enough for comparing endpoints and tracking changes over time.

## Known limitations

**OS scope**: Disk and network demand require Linux with a kernel newer than 3.14. On macOS and Windows you get CPU and heap only.

**Memory proxy**: Memory demand is derived from heap allocation, meaning bytes allocated by the thread, not bytes resident. A service that allocates heavily but holds little is overstated by the model; one that quietly holds a large long-lived heap is understated.

**Threading**: Resource-demand values are only valid when the thread that starts a span is the one that ends it. For reactive frameworks and virtual threads, where work can migrate between threads, OTJAE still attaches span attributes but does not publish metrics it cannot attribute reliably. For virtual threads specifically, memory demand cannot be captured at all today because the JVM does not expose it, and CPU time is attributed on the assumption that a virtual thread sitting on the same carrier thread at span start and end owns that carrier's CPU time.

**Overhead**: OTJAE reads resource-demand values twice per span, at start and at end. In the validation study [9] that cost nothing measurable: across three load levels, CPU utilisation stayed within 1.5 percentage points and system power within about 1 W of the uninstrumented baseline.

## What to try next

1. **Load test it**. The example ships an Apache JMeter [14] plan at `examples/spring-rest-service/src/test/resources/jmeter_testplan.jmx`. Run it and watch the dashboards update in real time — the numbers are most meaningful under load.

2. **Change the region**. Swap `eu-central-1` for `eu-north-1` and watch the same workload's CO2eq estimate fall without touching a line of code. The `io.retit.emissions.gef` gauge shows the factor the model is actually using: 338 g CO2eq/kWh for Frankfurt against 8 for Stockholm, both straight from the CCF dataset. Then try a coal-heavy region and watch it climb.

3. **Add an energy budget to CI**. Use the OpenTelemetry metrics endpoint to fail the build if a key transaction's CPU demand per request crosses a threshold.

## Conclusion

RAPL and OTJAE solve different problems. OTJAE's case is the deployment where RAPL cannot reach: it attributes consumption to individual transactions on any infrastructure, needs no code changes, and integrates with an OpenTelemetry pipeline teams may already run.

*The source code, examples, and pre-built dashboards are available at github.com/RETIT/opentelemetry-javaagent-extension [6] under the Apache 2.0 license.*

### About the author

Manuel Steinberg is a PhD candidate at Hochschule München (Munich University of Applied Sciences). His research focuses on measuring the energy footprint of software applications.

*Disclosure: the validation study [9] and the earlier SSP paper [15] come from the same research group; OTJAE is developed by RETIT.*

## References

[1] https://pmc.ncbi.nlm.nih.gov/articles/PMC8441580/
[2] https://www.iea.org/energy-system/transport/aviation
[3] https://eur-lex.europa.eu/eli/dir/2022/2464/oj/eng
[4] https://sci.greensoftware.foundation/ · https://www.iso.org/standard/86612.html
[5] https://github.com/joular/joularjx
[6] https://github.com/RETIT/opentelemetry-javaagent-extension
[7] https://github.com/open-telemetry/opentelemetry-java-instrumentation
[8] https://www.cloudcarbonfootprint.org/docs/methodology/
[9] https://doi.org/10.1145/3696630.3728709
[10] https://www.etsy.com/codeascraft/cloud-jewels-estimating-kwh-in-the-cloud
[11] https://www.spec.org/power_ssj2008/results/
[12] https://www.umweltbundesamt.de/themen/co2-emissionen-pro-kilowattstunde-strom-2024
[13] https://github.com/RETIT/opentelemetry-javaagent-extension/tree/main/examples
[14] https://jmeter.apache.org/
[15] https://dl.gi.de/items/3cbc03f9-64b5-41a8-be00-d45cea2412cb
[16] https://hotcarbon.org/assets/2026/paper-46.pdf
[17] https://dataviz.boavizta.org/
