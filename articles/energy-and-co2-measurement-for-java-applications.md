# Estimating Energy Consumption and CO2eq Emissions of Java Applications with OpenTelemetry

## Why software energy consumption matters

The ICT sector accounts for somewhere between 2 and 4 percent of global greenhouse gas emissions, depending on how far up the supply chain you count [1], which is comparable to aviation [2]. EU sustainability regulations are tightening, most notably the Corporate Sustainability Reporting Directive (CSRD) [3], and customers ask about the carbon footprint of the services they buy. The Green Software Foundation's Software Carbon Intensity (SCI) specification, now ISO/IEC 21031:2024 [4], standardizes software emissions per functional unit of work. But to pin energy on one Java application, or even a single HTTP request, you need both measurement and a model.

Specialized tools like JoularJX [5] read Intel's RAPL interface, which reports socket-level energy consumption from on-chip counters, sampled at short intervals [6]. RAPL is itself model-based on several processor generations, but it is the closest thing to a hardware reference a server offers. It needs direct hardware access, which AWS, Google Cloud, and Azure rarely grant on virtual instances. Model-based tools instead estimate energy from metrics that *are* available in the cloud, such as CPU time, heap allocation, disk and network I/O, and map them to power draw using published power data for the underlying hardware. The approach needs neither root access nor changes to the application code.

## What is OTJAE

The OpenTelemetry Java Agent Extension (OTJAE) [7] is an open-source extension for the official OpenTelemetry Java auto-instrumentation agent [8]. If you already use OpenTelemetry, adding OTJAE takes just one JVM flag or one dependency. It captures four resource-demand signals for every traced transaction, two of them on by default and two opt-in:

| Dimension | Unit | Platform |
|-----------|------|----------|
| CPU time  | milliseconds | Linux, macOS, Windows |
| Heap allocation | bytes | Linux, macOS, Windows |
| Disk I/O (read + write) | bytes | Linux (kernel >= 3.14; opt-in) |
| Network I/O (read + write) | bytes | Linux (kernel >= 3.14; opt-in) |

These signals feed an energy model that turns resource demand into hardware power, power into energy, and energy into CO2eq. The model works at two levels: the process as a whole and each transaction, so you can see which endpoints emit the most. The pre-built dashboards show the per-transaction view. The model follows the Cloud Carbon Footprint (CCF) methodology [9] and covers AWS, Azure, and GCP instances as well as on-premise hardware. For on-premise, you configure the CPU power, the data center's PUE (Power Usage Effectiveness, the ratio of total facility power to IT equipment power), the grid emissions factor, and the embodied emissions.

## How the numbers are calculated

![Per-transaction resource demand capture across applications](../img/extension_data_capture.png)

The CCF methodology turns the captured resource demand into power, as described and evaluated in [10, 11]. For CPU, the model takes the CPU utilization of the Java process and interpolates linearly between the processor's idle and maximum power per vCPU. It then attributes that power to an individual transaction according to the transaction's share of the process's CPU demand. The full idle power of the instance is therefore assigned to the JVM, which fits a container or VM that runs a single service. For memory, storage, and network, the model multiplies each transaction's demand by a CCF energy coefficient per GB.

Multiplying the attributed power by time gives energy. The model converts that energy to emissions using the region's grid emissions factor and adds a pro-rated share of the hardware's embodied emissions, the carbon released when the hardware was manufactured.

For cloud deployments, all of these values are pre-loaded from the CCF dataset: the processor's idle and maximum power, memory power, PUE, embodied emissions, and regional grid emissions factors.

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

Whichever option you pick, you need a backend. OTJAE emits standard OpenTelemetry signals, so any compatible backend works. If you don't have one, the repository [7] ships a docker-compose stack with Prometheus, Grafana, and an OpenTelemetry Collector. You'll find the start command in *Seeing it in practice*.

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

OTJAE now captures CPU and heap demand on every span. Disk and network follow in Step 3. The OpenTelemetry agent exports via OTLP over HTTP to `http://localhost:4318` by default, which the docker-compose stack from the repository accepts. For a different backend, add `-Dotel.exporter.otlp.endpoint=http://<your-collector>:4318`.

#### Step 3: Add the cloud or hardware profile for emissions estimates

Without a cloud profile, the extension captures resource demand but cannot convert it to energy or CO2eq. Add these three system properties to the Step 2 command, ahead of `-jar`:

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

For GCP or Azure, swap `aws` for `gcp` or `azure` and adjust region and instance type. For on-premise hardware, set `io.retit.emissions.cloud.provider=OnPremise` and supply idle and peak CPU power (from SPECpower_ssj2008 [12]), a PUE for your data center, your country's grid emissions factor, and the hardware's embodied emissions. For Germany, the 2024 factor [13] is roughly 363 g CO2eq/kWh, down from 433 in 2022. The extension's on-premise default is 342 g CO2eq/kWh, an ElectricityMaps figure for 2025.

The on-premise embodied-emissions default is zero, so manufacturing carbon is missing from your numbers until you set it, using data from your vendor or from Boavizta [14].

### Option B: Java dependency (Quarkus and CDI frameworks)

On a CDI-enabled framework such as Quarkus, the latest release [7] lets you skip the JVM flags: add a dependency and CDI's bean auto-discovery wires up the span processor.

The CDI library is currently distributed via GitHub Packages, not Maven Central, so `mvn compile` won't work out of the box. You need a GitHub personal access token (PAT) and a one-time entry in `~/.m2/settings.xml`. Gradle projects need the equivalent GitHub Packages repository and credentials.

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
  <version>v0.1.3-beta</version>
</dependency>
```

For Quarkus, `quarkus-opentelemetry` must also be on the classpath. It provides the SDK the library hooks into and is usually already present in any Quarkus service that exports traces.

#### Step 3: Configure via application.properties

The same OTJAE properties work in CDI mode, set through Quarkus's `application.properties`:

```properties
# OTLP exporter (gRPC, Quarkus default): point to your OpenTelemetry Collector
quarkus.otel.exporter.otlp.endpoint=http://localhost:4317

# OTJAE cloud profile
io.retit.emissions.cloud.provider=aws
io.retit.emissions.cloud.provider.region=eu-central-1
io.retit.emissions.cloud.provider.instance.type=t3.medium
```

Environment variables work too. Replace dots with underscores and use uppercase. A complete example is in the examples directory [15].

## Seeing it in practice

The repository [7] includes a Spring Boot example, the same application used in the validation study [10]. It exposes `GET /getData`, `POST /postData` and `DELETE /deleteData` under `http://localhost:8081/test-rest-endpoint/`, three endpoints that differ in how much work they do. You need JDK 21 or newer to build it and a running Docker daemon for the backend stack. The Maven build puts both agent JARs in `target/jib/otel/`. For your own application, use the JAR paths from Option A, Step 1.

```bash
# Build the project (jib.skip skips the container build, which needs a running Docker daemon)
./mvnw clean package -pl extension,examples/spring-rest-service -am -Djib.skip=true -DskipTests

# Start the backend (Prometheus + Grafana + OpenTelemetry Collector)
docker compose -f examples/docker/docker-compose.yml up -d
docker compose -f examples/docker/docker-compose.yml ps   # grafana, otel-col and prometheus should be up

# Run the instrumented app (AWS eu-central-1, t3.medium). It keeps this terminal busy.
cd examples/spring-rest-service
java -javaagent:./target/jib/otel/opentelemetry-javaagent.jar \
  -Dotel.javaagent.extensions=./target/jib/otel/io.retit.opentelemetry.javaagent.extension.jar \
  -Dotel.service.name=spring-app \
  -Dotel.logs.exporter=none \
  -Dio.retit.emissions.cloud.provider=aws \
  -Dio.retit.emissions.cloud.provider.region=eu-central-1 \
  -Dio.retit.emissions.cloud.provider.instance.type=t3.medium \
  -jar ./target/spring-rest-service.jar
```

Under the load below, the whole stack used about 250 MB of RAM on my machine:

```text
$ docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
NAME         CPU %     MEM USAGE / LIMIT
prometheus   0.01%     132.8MiB / 300MiB
grafana      0.06%     51.28MiB / 100MiB
otel-col     49.80%    68.42MiB / 125MiB
```

An idle app leaves the dashboards empty. The following loop sends requests to all three endpoints for 15 minutes. It is the load behind Figure 2. Your absolute values will depend on your machine, but the ranking of the three endpoints should be the same.

```bash
# In a second terminal
BASE=http://localhost:8081/test-rest-endpoint
end=$((SECONDS+900))   # run for 15 minutes
while [ $SECONDS -lt $end ]; do
  curl -s "$BASE/getData" -o /dev/null
  curl -s -X POST "$BASE/postData" -o /dev/null
  curl -s -X DELETE "$BASE/deleteData" -o /dev/null
done
```

Open `http://localhost:3000/grafana/dashboards`. Grafana is served from the `/grafana` sub-path, so the bare `http://localhost:3000` redirects to a URL without the port, which does not load.

![The pre-built Spring dashboard (OTJAE v0.1.3-beta, cloud profile AWS t3.medium in eu-central-1, a ten-minute window of the 15-minute load loop above): SCI in gCO2eq per minute for each transaction type, CPU demand per transaction and for the whole process, and the emission factors behind them.](spring_dashboard_v0.1.3_light.png)

Each endpoint now has its own Software Carbon Intensity (SCI) panel. It shows the gCO2eq that all requests to that endpoint cause per minute. Divide it by the number of requests per minute to get the SCI per request. The examples directory [15] also holds a Quarkus REST service with its own dashboard, plus plain-JDK examples for JDK 21 and JDK 8.

## Reading the metrics

Resource demand counters capture CPU time in milliseconds and heap, disk, and network I/O in bytes. OTJAE records them per transaction and tags them with the span's attributes, so you can query each transaction's demand directly. The four counters are `io.retit.resource.demand.cpu.ms`, `.memory.bytes`, `.storage.bytes` and `.network.bytes`. Process-wide CPU time is published separately as `io.retit.emissions.java.process.cpu.time`. In Prometheus, the first one is queried as `io_retit_resource_demand_cpu_ms_milliseconds_total`. In PromQL, `rate()` turns the cumulative counters into a per-second view.

OTJAE is built for synchronous request processing: resource-demand values are only valid when the thread that starts a span is the one that ends it. For reactive frameworks and virtual threads, where work can migrate between threads, OTJAE still attaches span attributes but does not publish metrics it cannot attribute reliably.

Emissions configuration metrics, published as OpenTelemetry gauges, carry the model's constants: idle and peak CPU power, the instance's vCPU count, grid emissions factor, PUE, and embodied emissions. The pre-built dashboards feed them into the SCI queries to compute CO2eq directly in Grafana. Most of them are also plotted in the Emission Calculation Factors panel.

Every span also carries the same demand as span attributes. That gives you trace-level profiling: open a slow request in any trace viewer, walk the span tree, and see how much CPU or heap each operation in the chain consumed. Full metric and attribute names are in the README [7].

## Accuracy in practice

A peer-reviewed study presented at the DevOpsSustain 2025 workshop [10] compared OTJAE's process-level estimate against RAPL readings on a bare-metal Xeon server (OTJAE v0.0.15-alpha). The dashboards in v0.1.3-beta implement the same model: recomputed with the study's measurement data, they reproduce its published per-transaction power values within 1.5 percent. The estimate got closer to RAPL as load increased. OTJAE's estimate ranged from 59 percent of the RAPL-measured power at 25 percent CPU utilization to 98 percent at 98 percent utilization, and stayed below RAPL at every load level.

The gap at low load is expected: power does not scale linearly with utilization. The study validated only the CPU model, at process level, on bare metal. The memory, storage, and network models, and the virtualized environments OTJAE is built for, have not been validated this way.

OTJAE reads resource-demand values twice per span, at start and at end. In the validation study [10], the overhead was too small to measure: across three load levels, CPU utilization stayed within 1.5 percentage points and system power within about 1 W of the uninstrumented baseline.

Below roughly 30 percent sustained CPU utilization, treat OTJAE numbers as a lower bound rather than an absolute figure. Above that, they are accurate enough for comparing endpoints and tracking changes over time.

## What to try next

1. Load test it. The example ships an Apache JMeter [16] plan at `examples/spring-rest-service/src/test/resources/jmeter_testplan.jmx`. Run it and watch the dashboards update in real time.

2. Change the region. For instance, swap `eu-central-1` for `eu-north-1`. The SCI panels drop, because the grid emissions factor falls from 0.338 kg CO2eq/kWh for Frankfurt to 0.008 for Stockholm, both from the CCF dataset. To check the factor the model is using, query `io_retit_emissions_gef` in Prometheus.

3. Add an energy budget to CI. Run a load test in your pipeline, query Prometheus for a key transaction's CPU demand per request, and fail the build if it crosses a threshold.

## Conclusion

OTJAE is a practical way to estimate the CO2eq emissions of Java applications in the cloud, where RAPL is usually not available. In the Spring example, the dashboards showed clear differences between the endpoints. In my run, a DELETE request used about four times as much CPU time as a GET request (19.4 ms versus 4.8 ms). Switching the region from Frankfurt to Stockholm lowered the grid emissions factor from 0.338 to 0.008 kg CO2eq/kWh without changing a line of code.

The validation study shows that the estimates come close to RAPL measurements under load and serve as a lower bound when the machine is mostly idle. Only the CPU model has been validated so far. For a pilot project that compares endpoints or tracks emissions across releases, OTJAE is a good starting point.

OTJAE is still in beta. At the time of writing (October 2026), the latest release is v0.1.3-beta. Metric names and configuration options may still change, so check the README [7] for the version you use.

*The source code, examples, and pre-built dashboards are available at github.com/RETIT/opentelemetry-javaagent-extension [7] under the Apache 2.0 license.*

### About the author

Manuel Steinberg is a PhD candidate at Hochschule München (Munich University of Applied Sciences). His research focuses on measuring the energy footprint of software applications.

*Disclosure: OTJAE is developed by RETIT GmbH.*

## References

[1] <https://pmc.ncbi.nlm.nih.gov/articles/PMC8441580/>

[2] <https://www.iea.org/energy-system/transport/aviation>

[3] <https://eur-lex.europa.eu/eli/dir/2022/2464/oj/eng>

[4] <https://sci.greensoftware.foundation/> · <https://www.iso.org/standard/86612.html>

[5] <https://github.com/joular/joularjx>

[6] <https://hotcarbon.org/assets/2026/paper-46.pdf>

[7] <https://github.com/RETIT/opentelemetry-javaagent-extension>

[8] <https://github.com/open-telemetry/opentelemetry-java-instrumentation>

[9] <https://www.cloudcarbonfootprint.org/docs/methodology/>

[10] <https://doi.org/10.1145/3696630.3728709>

[11] <https://dl.gi.de/items/3cbc03f9-64b5-41a8-be00-d45cea2412cb>

[12] <https://www.spec.org/power_ssj2008/results/>

[13] <https://www.umweltbundesamt.de/themen/co2-emissionen-pro-kilowattstunde-strom-2024>

[14] <https://dataviz.boavizta.org/>

[15] <https://github.com/RETIT/opentelemetry-javaagent-extension/tree/main/examples>

[16] <https://jmeter.apache.org/>
