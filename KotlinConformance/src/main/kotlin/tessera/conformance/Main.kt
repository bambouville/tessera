package tessera.conformance

import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.spec.NamedParameterSpec
import java.security.spec.XECPrivateKeySpec
import java.security.spec.XECPublicKeySpec
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.io.path.readBytes

private sealed interface JsonValue
private data class JsonObject(val values: LinkedHashMap<String, JsonValue>) : JsonValue
private data class JsonArray(val values: List<JsonValue>) : JsonValue
private data class JsonString(val value: String) : JsonValue
private data class JsonNumber(val source: String) : JsonValue
private data class JsonBoolean(val value: Boolean) : JsonValue
private data object JsonNull : JsonValue

/** Small strict JSON parser kept independent of Swift Codable and third-party JSON libraries. */
private class JsonParser(private val source: String) {
    private var offset = 0

    fun parse(): JsonValue {
        skipWhitespace()
        val value = parseValue()
        skipWhitespace()
        check(offset == source.length) { "trailing JSON data at byte $offset" }
        return value
    }

    private fun parseValue(): JsonValue {
        check(offset < source.length) { "unexpected end of JSON" }
        return when (source[offset]) {
            '{' -> parseObject()
            '[' -> parseArray()
            '"' -> JsonString(parseString())
            't' -> { literal("true"); JsonBoolean(true) }
            'f' -> { literal("false"); JsonBoolean(false) }
            'n' -> { literal("null"); JsonNull }
            '-', in '0'..'9' -> parseNumber()
            else -> error("unexpected JSON token at byte $offset")
        }
    }

    private fun parseObject(): JsonObject {
        expect('{')
        skipWhitespace()
        val values = linkedMapOf<String, JsonValue>()
        if (consume('}')) return JsonObject(values)
        while (true) {
            check(offset < source.length && source[offset] == '"') {
                "object key must be a string at byte $offset"
            }
            val key = parseString()
            check(key !in values) { "duplicate JSON key: $key" }
            skipWhitespace()
            expect(':')
            skipWhitespace()
            values[key] = parseValue()
            skipWhitespace()
            if (consume('}')) return JsonObject(values)
            expect(',')
            skipWhitespace()
        }
    }

    private fun parseArray(): JsonArray {
        expect('[')
        skipWhitespace()
        val values = mutableListOf<JsonValue>()
        if (consume(']')) return JsonArray(values)
        while (true) {
            values += parseValue()
            skipWhitespace()
            if (consume(']')) return JsonArray(values)
            expect(',')
            skipWhitespace()
        }
    }

    private fun parseString(): String {
        expect('"')
        val result = StringBuilder()
        while (offset < source.length) {
            val character = source[offset++]
            when (character) {
                '"' -> return result.toString()
                '\\' -> {
                    check(offset < source.length) { "unterminated JSON escape" }
                    when (val escaped = source[offset++]) {
                        '"', '\\', '/' -> result.append(escaped)
                        'b' -> result.append('\b')
                        'f' -> result.append('\u000C')
                        'n' -> result.append('\n')
                        'r' -> result.append('\r')
                        't' -> result.append('\t')
                        'u' -> result.append(parseUnicodeEscape())
                        else -> error("invalid JSON escape: \\$escaped")
                    }
                }
                else -> {
                    check(character.code >= 0x20) { "unescaped JSON control character" }
                    result.append(character)
                }
            }
        }
        error("unterminated JSON string")
    }

    private fun parseUnicodeEscape(): Char {
        check(offset + 4 <= source.length) { "truncated JSON unicode escape" }
        val digits = source.substring(offset, offset + 4)
        offset += 4
        return digits.toIntOrNull(16)?.toChar() ?: error("invalid JSON unicode escape")
    }

    private fun parseNumber(): JsonNumber {
        val start = offset
        consume('-')
        check(offset < source.length) { "truncated JSON number" }
        if (consume('0')) {
            check(offset == source.length || source[offset] !in '0'..'9') {
                "leading zero in JSON number"
            }
        } else {
            check(source[offset] in '1'..'9') { "invalid JSON number" }
            while (offset < source.length && source[offset] in '0'..'9') offset += 1
        }
        if (consume('.')) {
            check(offset < source.length && source[offset] in '0'..'9') {
                "missing JSON fractional digits"
            }
            while (offset < source.length && source[offset] in '0'..'9') offset += 1
        }
        if (offset < source.length && source[offset] in setOf('e', 'E')) {
            offset += 1
            if (offset < source.length && source[offset] in setOf('+', '-')) offset += 1
            check(offset < source.length && source[offset] in '0'..'9') {
                "missing JSON exponent digits"
            }
            while (offset < source.length && source[offset] in '0'..'9') offset += 1
        }
        return JsonNumber(source.substring(start, offset))
    }

    private fun literal(value: String) {
        check(source.startsWith(value, offset)) { "invalid JSON literal at byte $offset" }
        offset += value.length
    }

    private fun skipWhitespace() {
        while (offset < source.length && source[offset] in setOf(' ', '\t', '\r', '\n')) {
            offset += 1
        }
    }

    private fun expect(character: Char) {
        check(consume(character)) { "expected '$character' at byte $offset" }
    }

    private fun consume(character: Char): Boolean {
        if (offset < source.length && source[offset] == character) {
            offset += 1
            return true
        }
        return false
    }
}

private fun JsonValue.obj(): JsonObject = this as? JsonObject ?: error("expected JSON object")
private fun JsonValue.array(): List<JsonValue> = (this as? JsonArray)?.values ?: error("expected JSON array")
private fun JsonValue.string(): String = (this as? JsonString)?.value ?: error("expected JSON string")
private fun JsonValue.long(): Long = (this as? JsonNumber)?.source?.toLongExact()
    ?: error("expected integer JSON number")
private fun JsonValue.boolean(): Boolean = (this as? JsonBoolean)?.value ?: error("expected JSON boolean")
private operator fun JsonObject.get(key: String): JsonValue = values[key] ?: error("missing JSON key: $key")
private fun JsonObject.optional(key: String): JsonValue? = values[key]
private fun String.toLongExact(): Long? = if (matches(Regex("-?(0|[1-9][0-9]*)"))) toLongOrNull() else null

private class ContractError(val code: String) : IllegalStateException(code)

private class Conformance(private val vectors: Path) {
    private var assertions = 0
    private var groups = 0

    fun run() {
        test("continuation v1 schema, field spellings, and canonical descriptor", ::continuationSchema)
        test("continuation v1 rejection vectors and limits", ::continuationRejections)
        test("tmux topology and repaint vectors", ::tmuxVectors)
        test("tmux window-order v1 schema and shared plan outputs", ::windowOrderVectors)
        test("tmux render-ledger v1 schema and effect ordering", ::renderLedgerVectors)
        test("bootstrap manifest v2 field allowlists and limits", ::bootstrapManifest)
        test("public-key descriptor v1/v2 validation", ::publicKeyDescriptors)
        test("enrollment v1 bytes, framing, and role transitions", ::enrollmentV1)
        test("released nearby-bootstrap v2 complete transfer and limits", ::legacyNearbyBootstrapV2)
        test("pairing v1 canonical transcript, X25519/HKDF material, and SAS", ::pairingDeterminism)
        test("pairing v1 expiry, downgrade, and terminal rejection vectors", ::pairingRejections)
        test("continuation transaction v1 envelopes, abort, and terminal states", ::continuationTransaction)
        test("bootstrap transaction v1 receipts, abort, and terminal states") { bootstrapTransaction(1) }
        test("bootstrap transaction v2 receipts, canonical encoding, and v1 delta") { bootstrapTransaction(2) }
        test("session challenge generation, limits, and one-shot responses", ::sessionChallenges)
        println("Kotlin conformance passed: $groups tests, $assertions assertions")
    }

    /** Independent schema consumer; command planning remains exclusively in Swift. */
    private fun windowOrderVectors() {
        val vector = parse("tmux/window-order-v1.json")
        requireExactKeys(vector, setOf("version", "cases"), "window-order root")
        checkThat(vector["version"].long() == 1L, "window-order vector version drifted")
        val names = mutableSetOf<String>()
        val windowID = Regex("@[0-9]+")
        val sessionID = Regex("\\$[0-9]+")
        val cases = vector["cases"].array()
        checkThat(cases.isNotEmpty(), "window-order vectors must not be empty")
        cases.forEachIndexed { index, value ->
            val entry = value.obj()
            requireExactKeys(entry, setOf("name", "request", "response", "serverOrder"), "window-order case $index")
            val name = entry["name"].string()
            checkThat(name.isNotBlank() && names.add(name), "window-order case names must be unique")

            val request = entry["request"].obj()
            requireExactKeys(
                request,
                setOf("order", "moving", "destination", "capabilities", "sessionID", "activeWindowID", "highestIndex"),
                "$name request",
            )
            val order = request["order"].array().map(JsonValue::string)
            checkThat(order.isNotEmpty() && order.size <= 512 && order.toSet().size == order.size, "$name order is invalid")
            checkThat(order.all(windowID::matches), "$name order contains an invalid id")
            checkThat(request["moving"].string() in order, "$name moving id is absent")
            checkThat(request["destination"].long() in order.indices.map(Int::toLong), "$name destination is invalid")
            checkThat(sessionID.matches(request["sessionID"].string()), "$name session id is invalid")
            checkThat(request["activeWindowID"].string() in order, "$name active window is absent")
            checkThat(request["highestIndex"].long() in 0L..1_000_000L, "$name highest index is invalid")
            val capabilities = request["capabilities"].obj()
            requireExactKeys(capabilities, setOf("supportsMoveBefore", "supportsSubscriptions"), "$name capabilities")
            capabilities["supportsMoveBefore"].boolean()
            capabilities["supportsSubscriptions"].boolean()

            val response = entry["response"].obj()
            requireExactKeys(response, setOf("commands", "expectedOrder"), "$name response")
            val commands = response["commands"].array().map(JsonValue::string)
            checkThat(commands.size <= 3 && commands.none(String::isBlank), "$name command sequence is invalid")
            val expectedOrder = response["expectedOrder"].array().map(JsonValue::string)
            val serverOrder = entry["serverOrder"].array().map(JsonValue::string)
            checkThat(expectedOrder == serverOrder, "$name shared expected order differs from server result")
            checkThat(expectedOrder.toSet() == order.toSet(), "$name expected order is not a permutation")
        }
    }

    private fun test(name: String, body: () -> Unit) {
        try {
            body()
            groups += 1
            println("PASS $name")
        } catch (error: Throwable) {
            throw AssertionError("FAIL $name: ${error.message}", error)
        }
    }

    private fun checkThat(condition: Boolean, message: String) {
        assertions += 1
        check(condition) { message }
    }

    private fun parse(relative: String): JsonObject = parseBytes(relative).obj()

    private fun parseBytes(relative: String): JsonValue {
        val path = vectors.resolve(relative).normalize()
        checkThat(path.startsWith(vectors), "vector path escaped root")
        val bytes = path.readBytes()
        return JsonParser(bytes.toString(StandardCharsets.UTF_8)).parse()
    }

    private fun continuationSchema() {
        val schema = parse("continuation/v1/schema.json")
        val required = schema["required"].array().map(JsonValue::string).toSet()
        val expectedRequired = setOf(
            "v", "hostID", "connectionKey", "name", "user", "address", "port",
            "transport", "launchMode", "via",
        )
        checkThat(required == expectedRequired, "continuation required field names drifted")
        val properties = schema["properties"].obj().values.keys
        checkThat(
            properties == setOf(
                "v", "hostID", "connectionKey", "name", "user", "address", "port",
                "transport", "launchMode", "tmux", "hostKeyFP", "via",
            ),
            "continuation public field spellings drifted",
        )
        checkThat(schema["additionalProperties"].boolean(), "released continuation unknown-field tolerance changed")
        val endpoint = schema["\$defs"].obj()["endpoint"].obj()
        checkThat(endpoint["additionalProperties"].boolean(), "released endpoint unknown-field tolerance changed")
        checkThat(
            endpoint["required"].array().map(JsonValue::string).toSet() ==
                setOf("hostID", "name", "user", "address", "port", "transport"),
            "continuation endpoint required fields drifted",
        )

        val canonicalBytes = vectors.resolve("continuation/v1/canonical.json").readBytes()
        val canonical = JsonParser(canonicalBytes.toString(StandardCharsets.UTF_8)).parse().obj()
        checkThat(canonical.values.keys == properties, "canonical continuation fields differ from schema")
        validateContinuation(canonical, canonicalBytes.size)
        checkThat(canonical["v"].long() == 1L, "continuation canonical version is not v1")
        checkThat(canonical["hostKeyFP"].string() == "SHA256:destination", "hostKeyFP spelling/value drifted")
        checkThat(canonical["tmux"].string() == "dev", "tmux field spelling/value drifted")
    }

    private fun continuationRejections() {
        expectCode("unsupportedSchemaVersion") {
            validateContinuation(parse("continuation/v1/invalid-schema-version.json"), 1)
        }
        expectCode("invalidPort") {
            validateContinuation(parse("continuation/v1/invalid-port.json"), 1)
        }
        expectCode("missingTmuxSessionName") {
            validateContinuation(parse("continuation/v1/invalid-missing-tmux.json"), 1)
        }
        expectCode("connectionKeyMismatch") {
            validateContinuation(parse("continuation/v1/invalid-connection-key.json"), 1)
        }
        val limits = parse("continuation/v1/limits.json")
        checkThat(limits["maximumHandoffBytes"].long() == 3_072L, "handoff byte limit drifted")
        checkThat(limits["maximumViaCount"].long() == 8L, "continuation route limit drifted")
        expectCode("exceedsHandoffBudget") {
            validateContinuation(parse("continuation/v1/canonical.json"), 3_073)
        }
        expectCode("tooManyViaEndpoints") { checkMaximum(9, 8, "tooManyViaEndpoints") }
    }

    private fun validateContinuation(root: JsonObject, encodedBytes: Int) {
        if (encodedBytes > 3_072) throw ContractError("exceedsHandoffBudget")
        if (root["v"].long() != 1L) throw ContractError("unsupportedSchemaVersion")
        val port = root["port"].long()
        if (port !in 1..65_535) throw ContractError("invalidPort")
        val via = root["via"].array()
        if (via.size > 8) throw ContractError("tooManyViaEndpoints")
        val routeIDs = mutableSetOf<String>()
        via.forEach { value ->
            val endpoint = value.obj()
            val candidatePort = endpoint["port"].long()
            if (candidatePort !in 1..65_535) throw ContractError("invalidPort")
            if (!routeIDs.add(endpoint["hostID"].string())) throw ContractError("duplicateRouteHostID")
        }
        if (!routeIDs.add(root["hostID"].string())) throw ContractError("duplicateRouteHostID")
        val launchMode = root["launchMode"].string()
        val tmux = root.optional("tmux")?.string()
        if (launchMode in setOf("autoTmux", "pinnedTmux") && tmux.isNullOrBlank()) {
            throw ContractError("missingTmuxSessionName")
        }
        if (launchMode == "customCommand" && tmux != null) throw ContractError("unexpectedTmuxSessionName")
        checkThat(launchMode in setOf("autoTmux", "pinnedTmux", "customCommand"), "invalid launch mode")
        checkThat(root["transport"].string() in setOf("ssh", "mosh"), "invalid continuation transport")
        val expectedConnectionKey = buildString {
            append(root["transport"].string())
            append(':')
            append(root["user"].string())
            append('@')
            append(root["address"].string())
            append(':')
            append(port)
            if (via.isNotEmpty()) {
                append("&via=")
                append(via.joinToString(",") { it.obj()["hostID"].string() })
            }
        }
        if (root["connectionKey"].string() != expectedConnectionKey) {
            throw ContractError("connectionKeyMismatch")
        }
    }

    private fun tmuxVectors() {
        data class WindowState(var name: String = "", var activePaneID: Long? = null)

        val expected = parse("tmux/basic-topology.snapshot.json")
        val windows = linkedMapOf<Long, WindowState>()
        var sessionID: Long? = null
        var sessionName: String? = null
        var activeWindowID: Long? = null
        var authorityDeviceID: String? = null
        var authorityGeneration: Long? = null
        var authorityDisplayName: String? = null
        vectors.resolve("tmux/basic-topology.trace").toFile().readLines().forEach { line ->
            val fields = line.split(' ')
            when (fields.firstOrNull()) {
                "%session-changed" -> {
                    sessionID = fields[1].removePrefix("\$").toLong()
                    sessionName = fields.drop(2).joinToString(" ")
                }
                "%window-add" -> windows[fields[1].removePrefix("@").toLong()] = WindowState()
                "%window-renamed" -> {
                    windows.getValue(fields[1].removePrefix("@").toLong()).name =
                        fields.drop(2).joinToString(" ")
                }
                "%window-pane-changed" -> {
                    windows.getValue(fields[1].removePrefix("@").toLong()).activePaneID =
                        fields[2].removePrefix("%").toLong()
                }
                "%session-window-changed" -> {
                    activeWindowID = fields[2].removePrefix("@").toLong()
                }
                "%subscription-changed" -> {
                    checkThat(fields[7] == "v1", "tmux authority vector version drifted")
                    authorityDeviceID = fields[8]
                    authorityGeneration = fields[9].toLong()
                    authorityDisplayName = fields.drop(10).joinToString(" ")
                }
            }
        }

        checkThat(sessionID == expected["sessionID"].obj()["rawValue"].long(), "tmux session ID drifted")
        checkThat(sessionName == expected["sessionName"].string(), "tmux session name drifted")
        checkThat(
            activeWindowID == expected["activeWindowID"].obj()["rawValue"].long(),
            "tmux active window drifted",
        )
        val expectedWindows = expected["windows"].array()
        checkThat(windows.size == expectedWindows.size, "tmux window count drifted")
        expectedWindows.forEach { value ->
            val window = value.obj()
            val id = window["id"].obj()["rawValue"].long()
            val actual = windows[id]
            checkThat(actual != null, "tmux window @$id is missing")
            checkThat(actual?.name == window["name"].string(), "tmux window @$id name drifted")
            checkThat(
                actual?.activePaneID == window["activePaneID"].obj()["rawValue"].long(),
                "tmux window @$id active pane drifted",
            )
        }
        val peer = expected["authority"].obj()["peer"].obj()
        checkThat(authorityDeviceID == peer["deviceID"].string(), "tmux authority device drifted")
        checkThat(authorityGeneration == peer["generation"].long(), "tmux authority generation drifted")
        checkThat(authorityDisplayName == peer["displayName"].string(), "tmux authority name drifted")

        val repaint = parse("tmux/repaint-v1.json")
        val repaintBytes = decodeBase64(repaint["expectedBase64"].string())
        val expectedLine = repaint["captureLines"].array().single().string()
        checkThat(
            repaintBytes.toString(StandardCharsets.UTF_8).contains("$expectedLine\u001b[0m"),
            "tmux repaint lost the captured line or reset",
        )
        checkThat(
            repaintBytes.toString(StandardCharsets.UTF_8).endsWith("\u001b[2;3H"),
            "tmux repaint cursor placement drifted",
        )
        val stateFields = repaint["renderedStateLine"].string().split('\t')
        checkThat(stateFields.size == 22, "tmux rendered-state field count drifted")
        checkThat(
            stateFields[9].toLong() == repaint["clientRows"].long() - 1,
            "tmux rendered-state client row relationship drifted",
        )
        checkThat(!repaint["terminalIsInAltScreen"].boolean(), "tmux repaint alt-screen expectation drifted")
    }

    /**
     * This is intentionally a schema/order consumer, not a second reducer.
     * Android executes the cases through JNI in core-bridge instrumentation;
     * this independently verifies that the checked-in contract is parsable,
     * has no ambiguous optional fields, and preserves the executor ordering
     * dependencies that a platform must observe.
     */
    private fun renderLedgerVectors() {
        val vector = parse("tmux/render-ledger-v1.json")
        requireExactKeys(vector, setOf("version", "cases", "abiCases"), "render-ledger root")
        checkThat(vector["version"].long() == 1L, "render-ledger vector version drifted")
        val names = mutableSetOf<String>()
        val coreCases = vector["cases"].array()
        val abiCases = vector["abiCases"].array()
        checkThat(coreCases.isNotEmpty(), "render-ledger core vectors must not be empty")
        checkThat(abiCases.isNotEmpty(), "render-ledger ABI vectors must not be empty")
        fun validateCases(values: List<JsonValue>, section: String, allowsPlatformCommands: Boolean) {
            values.forEachIndexed { caseIndex, value ->
                val case = value.obj()
                requireExactKeys(case, setOf("name", "steps", "expectedEffects"), "$section case $caseIndex")
                val name = case["name"].string()
                checkThat(name.isNotBlank() && names.add(name), "render-ledger case name must be unique and nonblank")
                val platformCommandCount = case["steps"].array().mapIndexed { stepIndex, step ->
                    decodeRenderLedgerStep(step.obj(), "$name step $stepIndex", allowsPlatformCommands)
                }.count { it }
                if (allowsPlatformCommands) {
                    checkThat(platformCommandCount > 0, "$name ABI case must exercise a platform command")
                }
                val effects = case["expectedEffects"].array().mapIndexed { effectIndex, effect ->
                    decodeRenderLedgerEffect(effect.obj(), "$name effect $effectIndex")
                }
                checkThat(effects.isNotEmpty(), "$name must declare ordered render effects")
                checkRenderLedgerEffectOrdering(effects, name, platformCommandCount)
            }
        }
        validateCases(coreCases, "render-ledger", allowsPlatformCommands = false)
        validateCases(abiCases, "render-ledger ABI", allowsPlatformCommands = true)
        checkThat(names.isNotEmpty(), "render-ledger vectors must not be empty")
    }

    private data class RenderLedgerOwner(
        val windowID: Long?,
        val paneID: Long?,
        val epoch: Long,
    )

    private data class RenderLedgerEffect(
        val kind: String,
        val surfaceID: String? = null,
        val owner: RenderLedgerOwner? = null,
        val windowID: Long? = null,
        val timer: Long? = null,
        val tag: Long? = null,
        val correlation: Long? = null,
    )

    private fun decodeRenderLedgerStep(
        step: JsonObject,
        context: String,
        allowsPlatformCommands: Boolean,
    ): Boolean {
        requireExactKeys(step, setOf("input"), context)
        val input = step["input"].obj()
        return when (input["kind"].string()) {
            "wire" -> {
                requireExactKeys(input, setOf("kind", "wire"), context)
                checkThat(input["wire"].string().isNotEmpty(), "$context wire input must not be empty")
                false
            }
            "fact" -> {
                requireExactKeys(input, setOf("kind", "fact"), context)
                decodeRenderLedgerFact(input["fact"].obj(), context)
                false
            }
            "platformCommand" -> {
                checkThat(allowsPlatformCommands, "$context platform commands belong only in ABI cases")
                requireExactKeys(input, setOf("kind", "command"), context)
                input["command"].nonBlank("$context platform command")
                true
            }
            else -> error("$context has an unknown render-ledger input kind")
        }
    }

    private fun decodeRenderLedgerFact(fact: JsonObject, context: String) {
        checkThat(fact["version"].long() == 1L, "$context render fact version drifted")
        when (fact["kind"].string()) {
            "transportAttached" -> {
                requireExactKeys(fact, setOf("version", "kind", "profile"), context)
                checkThat(fact["profile"].string() in setOf("inline", "sideChannel"), "$context invalid profile")
            }
            "transportLost", "appForeground", "appBackground", "userInput" ->
                requireExactKeys(fact, setOf("version", "kind"), context)
            "surfacesDeclared" -> {
                requireExactKeys(fact, setOf("version", "kind", "surfaces"), context)
                fact["surfaces"].array().forEachIndexed { index, value ->
                    val surface = value.obj()
                    checkThat(
                        surface.values.keys.containsAll(setOf("surfaceID", "presentation"))
                            && surface.values.keys.all { it in setOf("surfaceID", "presentation", "windowID", "paneID") },
                        "$context surface $index has unexpected fields",
                    )
                    checkThat(surface["surfaceID"].string().isNotBlank(), "$context surface id is blank")
                    checkThat(
                        surface["presentation"].string() in setOf("single", "grid", "overlay"),
                        "$context surface presentation is invalid",
                    )
                    surface.optional("windowID")?.nonNegativeLong("$context surface windowID")
                    surface.optional("paneID")?.nonNegativeLong("$context surface paneID")
                }
            }
            "clientSize" -> {
                requireExactKeys(fact, setOf("version", "kind", "columns", "rows"), context)
                fact["columns"].positiveLong("$context columns")
                fact["rows"].positiveLong("$context rows")
            }
            "surfaceState" -> {
                requireExactKeys(
                    fact,
                    setOf("version", "kind", "surfaceID", "request", "altScreen", "mouseMode", "columns", "rows"),
                    context,
                )
                fact["surfaceID"].nonBlank("$context surfaceID")
                fact["request"].positiveLong("$context request")
                fact["altScreen"].boolean()
                checkThat(fact["mouseMode"].string() in setOf("off", "tracking"), "$context mouse mode is invalid")
                fact["columns"].positiveLong("$context columns")
                fact["rows"].positiveLong("$context rows")
            }
            "timerFired" -> {
                requireExactKeys(fact, setOf("version", "kind", "token"), context)
                fact["token"].positiveLong("$context token")
            }
            "scrollbackRequested" -> {
                requireExactKeys(fact, setOf("version", "kind", "surfaceID", "pointsY", "isInertial"), context)
                fact["surfaceID"].nonBlank("$context surfaceID")
                fact["pointsY"].finiteNumber("$context pointsY")
                fact["isInertial"].boolean()
            }
            "scrollbackReturnedToTail", "findOpened" -> {
                requireExactKeys(fact, setOf("version", "kind", "surfaceID"), context)
                fact["surfaceID"].nonBlank("$context surfaceID")
            }
            "scrollbackLimit" -> {
                requireExactKeys(fact, setOf("version", "kind", "lines"), context)
                fact["lines"].nonNegativeLong("$context lines")
            }
            "refreshRequested" -> {
                requireExactKeys(fact, setOf("version", "kind", "surfaceID", "stage", "reason"), context)
                fact["surfaceID"].nonBlank("$context surfaceID")
                checkThat(fact["stage"].string() in setOf("viewport", "viewportOnly", "deep"), "$context stage is invalid")
                fact["reason"].nonBlank("$context reason")
            }
            "correlatedRefreshRequested" -> {
                requireExactKeys(
                    fact,
                    setOf("version", "kind", "surfaceID", "stage", "reason", "correlation"),
                    context,
                )
                fact["surfaceID"].nonBlank("$context surfaceID")
                checkThat(fact["stage"].string() in setOf("viewport", "viewportOnly", "deep"), "$context stage is invalid")
                fact["reason"].nonBlank("$context reason")
                // Zero is a deliberate rejection input: the ledger refuses it.
                fact["correlation"].nonNegativeLong("$context refresh correlation")
            }
            "historyPresented", "historyPresentationFailed" -> {
                requireExactKeys(fact, setOf("version", "kind", "surfaceID", "owner"), context)
                fact["surfaceID"].nonBlank("$context surfaceID")
                decodeRenderLedgerOwner(fact["owner"].obj(), context)
            }
            "correlatedTransportFullFrameRequested" -> {
                requireExactKeys(fact, setOf("version", "kind", "surfaceID", "reason", "correlation"), context)
                fact["surfaceID"].nonBlank("$context surfaceID")
                fact["reason"].nonBlank("$context reason")
                fact["correlation"].nonNegativeLong("$context transport frame correlation")
            }
            "transportFullFramePresented", "transportFullFramePresentationFailed" -> {
                val keys = setOf("version", "kind", "surfaceID", "owner", "correlation") +
                    if (fact["kind"].string() == "transportFullFramePresentationFailed") setOf("reason") else emptySet()
                checkThat(
                    fact.values.keys.all { it in keys } &&
                        fact.values.keys.containsAll(keys - setOf("owner")),
                    "$context transport frame report has unexpected fields",
                )
                fact["surfaceID"].nonBlank("$context surfaceID")
                // Absent for a reservation acknowledged before the surface's
                // first bind; the frame rode the untagged painter feed.
                fact.optional("owner")?.let { decodeRenderLedgerOwner(it.obj(), context) }
                fact["correlation"].positiveLong("$context transport frame correlation")
                if (fact["kind"].string() == "transportFullFramePresentationFailed") {
                    fact["reason"].nonBlank("$context reason")
                }
            }
            else -> error("$context has an unknown render fact kind")
        }
    }

    private fun decodeRenderLedgerEffect(effect: JsonObject, context: String): RenderLedgerEffect =
        when (effect["kind"].string()) {
            "sendCommand" -> {
                requireExactKeys(effect, setOf("kind", "command"), context)
                RenderLedgerEffect("sendCommand").also {
                    effect["command"].nonBlank("$context command")
                }
            }
            "commandReply" -> {
                requireExactKeys(effect, setOf("kind", "tag", "success", "lines"), context)
                effect["tag"].positiveLong("$context command reply tag")
                effect["success"].boolean()
                effect["lines"].array().forEach { it.string() }
                RenderLedgerEffect("commandReply", tag = effect["tag"].long())
            }
            "bindSurface" -> {
                requireExactKeys(effect, setOf("kind", "surfaceID", "owner"), context)
                val surfaceID = effect["surfaceID"].nonBlank("$context surfaceID")
                RenderLedgerEffect("bindSurface", surfaceID, decodeRenderLedgerOwner(effect["owner"].obj(), context))
            }
            "feed" -> {
                requireExactKeys(effect, setOf("kind", "surfaceID", "owner", "source", "bytes"), context)
                val surfaceID = effect["surfaceID"].nonBlank("$context surfaceID")
                checkThat(
                    effect["source"].string() in setOf(
                        "pane-output", "tmux-repaint-viewport", "tmux-repaint-viewport-refresh",
                        "tmux-repaint-deep", "tmux-repaint-scrub", "foreground-replay", "mosh-history",
                    ),
                    "$context feed source is invalid",
                )
                val bytes = effect["bytes"].obj()
                requireExactKeys(bytes, setOf("length", "sha256"), "$context feed bytes")
                bytes["length"].nonNegativeLong("$context feed byte length")
                checkThat(
                    bytes["sha256"].string().matches(Regex("[0-9a-f]{64}")),
                    "$context feed digest must be lowercase SHA-256",
                )
                RenderLedgerEffect("feed", surfaceID, decodeRenderLedgerOwner(effect["owner"].obj(), context))
            }
            "saveWindowModes" -> {
                requireExactKeys(effect, setOf("kind", "surfaceID", "windowID"), context)
                RenderLedgerEffect(
                    "saveWindowModes",
                    effect["surfaceID"].nonBlank("$context surfaceID"),
                    windowID = effect["windowID"].nonNegativeLong("$context windowID"),
                )
            }
            "restoreWindowModes" -> {
                requireExactKeys(effect, setOf("kind", "surfaceID", "windowID", "paneInAltScreen"), context)
                effect["paneInAltScreen"].boolean()
                RenderLedgerEffect(
                    "restoreWindowModes",
                    effect["surfaceID"].nonBlank("$context surfaceID"),
                    windowID = effect["windowID"].nonNegativeLong("$context windowID"),
                )
            }
            "resolveSurfaceState" -> {
                requireExactKeys(effect, setOf("kind", "surfaceID", "request"), context)
                effect["request"].positiveLong("$context surface-state request")
                RenderLedgerEffect("resolveSurfaceState", effect["surfaceID"].nonBlank("$context surfaceID"))
            }
            "armTimer" -> {
                requireExactKeys(effect, setOf("kind", "token", "milliseconds"), context)
                val token = effect["token"].positiveLong("$context timer token")
                effect["milliseconds"].nonNegativeLong("$context timer milliseconds")
                RenderLedgerEffect("armTimer", timer = token)
            }
            "cancelTimer" -> {
                requireExactKeys(effect, setOf("kind", "token"), context)
                RenderLedgerEffect("cancelTimer", timer = effect["token"].positiveLong("$context timer token"))
            }
            "initialRenderReady", "requestTransportFullFrame" -> {
                requireExactKeys(effect, setOf("kind"), context)
                RenderLedgerEffect(effect["kind"].string())
            }
            "historyReady" -> {
                requireExactKeys(
                    effect,
                    setOf("kind", "surfaceID", "owner", "depth", "historySize", "placement"),
                    context,
                )
                effect["depth"].nonNegativeLong("$context history depth")
                effect["historySize"].nonNegativeLong("$context history size")
                checkThat(
                    effect["placement"].string() in setOf("bottom", "preserveDistanceFromBottom"),
                    "$context history placement is invalid",
                )
                RenderLedgerEffect(
                    "historyReady",
                    effect["surfaceID"].nonBlank("$context surfaceID"),
                    decodeRenderLedgerOwner(effect["owner"].obj(), context),
                )
            }
            "inlineHistorySettled" -> {
                requireExactKeys(
                    effect,
                    setOf("kind", "surfaceID", "owner", "depth", "historySize", "canDeepen"),
                    context,
                )
                effect["depth"].nonNegativeLong("$context inline history depth")
                effect["historySize"].nonNegativeLong("$context inline history size")
                effect["canDeepen"].boolean()
                RenderLedgerEffect(
                    "inlineHistorySettled",
                    effect["surfaceID"].nonBlank("$context surfaceID"),
                    decodeRenderLedgerOwner(effect["owner"].obj(), context),
                )
            }
            "refreshCompleted" -> {
                requireExactKeys(effect, setOf("kind", "surfaceID", "owner", "stage", "correlation"), context)
                checkThat(
                    effect["stage"].string() in setOf("viewport", "viewportOnly", "deep"),
                    "$context stage is invalid",
                )
                RenderLedgerEffect(
                    "refreshCompleted",
                    effect["surfaceID"].nonBlank("$context surfaceID"),
                    decodeRenderLedgerOwner(effect["owner"].obj(), context),
                    correlation = effect["correlation"].positiveLong("$context refresh correlation"),
                )
            }
            "refreshFailed" -> {
                requireExactKeys(effect, setOf("kind", "surfaceID", "correlation", "reason"), context)
                effect["reason"].nonBlank("$context reason")
                RenderLedgerEffect(
                    "refreshFailed",
                    effect["surfaceID"].nonBlank("$context surfaceID"),
                    correlation = effect["correlation"].nonNegativeLong("$context refresh correlation"),
                )
            }
            "requestCorrelatedTransportFullFrame" -> {
                checkThat(
                    effect.values.keys.all { it in setOf("kind", "surfaceID", "owner", "correlation", "reason") } &&
                        effect.values.keys.containsAll(setOf("kind", "surfaceID", "correlation", "reason")),
                    "$context transport frame request has unexpected fields",
                )
                effect["reason"].nonBlank("$context reason")
                RenderLedgerEffect(
                    "requestCorrelatedTransportFullFrame",
                    effect["surfaceID"].nonBlank("$context surfaceID"),
                    // Absent until the surface's first bind: the reservation is
                    // deliberately accepted before one exists.
                    effect.optional("owner")?.let { decodeRenderLedgerOwner(it.obj(), context) },
                    correlation = effect["correlation"].positiveLong("$context transport frame correlation"),
                )
            }
            "transportFullFrameCompleted" -> {
                checkThat(
                    effect.values.keys.all { it in setOf("kind", "surfaceID", "owner", "correlation") } &&
                        effect.values.keys.containsAll(setOf("kind", "surfaceID", "correlation")),
                    "$context transport frame completion has unexpected fields",
                )
                RenderLedgerEffect(
                    "transportFullFrameCompleted",
                    effect["surfaceID"].nonBlank("$context surfaceID"),
                    effect.optional("owner")?.let { decodeRenderLedgerOwner(it.obj(), context) },
                    correlation = effect["correlation"].positiveLong("$context transport frame correlation"),
                )
            }
            "transportFullFrameFailed" -> {
                requireExactKeys(effect, setOf("kind", "surfaceID", "correlation", "reason"), context)
                effect["reason"].nonBlank("$context reason")
                RenderLedgerEffect(
                    "transportFullFrameFailed",
                    effect["surfaceID"].nonBlank("$context surfaceID"),
                    correlation = effect["correlation"].nonNegativeLong("$context transport frame correlation"),
                )
            }
            "diagnostic" -> {
                requireExactKeys(effect, setOf("kind", "message"), context)
                effect["message"].nonBlank("$context diagnostic")
                RenderLedgerEffect("diagnostic")
            }
            else -> error("$context has an unknown render effect kind")
        }

    private fun decodeRenderLedgerOwner(owner: JsonObject, context: String): RenderLedgerOwner {
        checkThat(
            owner.values.keys.contains("epoch")
                && owner.values.keys.all { it in setOf("windowID", "paneID", "epoch") },
            "$context render owner has unexpected fields",
        )
        return RenderLedgerOwner(
            windowID = owner.optional("windowID")?.nonNegativeLong("$context owner windowID"),
            paneID = owner.optional("paneID")?.nonNegativeLong("$context owner paneID"),
            epoch = owner["epoch"].nonNegativeLong("$context owner epoch"),
        )
    }

    private fun checkRenderLedgerEffectOrdering(
        effects: List<RenderLedgerEffect>,
        name: String,
        platformCommandCount: Int,
    ) {
        val boundOwners = mutableMapOf<String, RenderLedgerOwner>()
        val fedOwners = mutableMapOf<String, RenderLedgerOwner>()
        val armedTimers = mutableSetOf<Long>()
        val commandReplyTags = mutableListOf<Long>()
        // Correlation -> the owner the reservation is currently issued against.
        // Present means outstanding; removed means terminated. The ledger
        // promises exactly one terminal outcome per accepted reservation, and a
        // platform that trusts that promise strands its claim if it is broken.
        val openTransportFrames = mutableMapOf<Long, RenderLedgerOwner?>()
        var sawFeed = false
        effects.forEachIndexed { index, effect ->
            when (effect.kind) {
                "requestCorrelatedTransportFullFrame" -> {
                    val correlation = requireNotNull(effect.correlation)
                    val surfaceID = requireNotNull(effect.surfaceID)
                    if (openTransportFrames.containsKey(correlation)) {
                        // A re-issue: only a rebind produces one, and it must
                        // name the owner that bind installed.
                        checkThat(
                            boundOwners[surfaceID] == effect.owner && effect.owner != null,
                            "$name effect $index re-issues a transport frame for an unbound owner",
                        )
                        checkThat(
                            openTransportFrames[correlation] != effect.owner,
                            "$name effect $index re-issues a transport frame for the owner it already had",
                        )
                    }
                    openTransportFrames[correlation] = effect.owner
                }
                "transportFullFrameCompleted", "transportFullFrameFailed" -> {
                    val correlation = requireNotNull(effect.correlation)
                    checkThat(
                        openTransportFrames.containsKey(correlation),
                        "$name effect $index terminates a transport frame that is not outstanding",
                    )
                    openTransportFrames.remove(correlation)
                }
                "armTimer" -> armedTimers += requireNotNull(effect.timer)
                "cancelTimer" -> checkThat(
                    armedTimers.remove(requireNotNull(effect.timer)),
                    "$name effect $index cancels an unarmed timer",
                )
                "commandReply" -> commandReplyTags += requireNotNull(effect.tag)
                "bindSurface" -> boundOwners[requireNotNull(effect.surfaceID)] = requireNotNull(effect.owner)
                "feed" -> {
                    val surfaceID = requireNotNull(effect.surfaceID)
                    checkThat(
                        boundOwners[surfaceID] == effect.owner,
                        "$name effect $index feeds before the matching surface bind",
                    )
                    fedOwners[surfaceID] = requireNotNull(effect.owner)
                    sawFeed = true
                }
                "restoreWindowModes" -> {
                    val surfaceID = requireNotNull(effect.surfaceID)
                    checkThat(
                        fedOwners[surfaceID]?.windowID == effect.windowID,
                        "$name effect $index restores modes before that window has been fed",
                    )
                }
                "historyReady" -> checkThat(
                    fedOwners[effect.surfaceID] == effect.owner,
                    "$name effect $index announces history before its feed",
                )
                "initialRenderReady" -> checkThat(
                    sawFeed,
                    "$name declares initial render readiness before a feed",
                )
            }
        }
        checkThat(
            commandReplyTags.size == platformCommandCount,
            "$name must produce exactly one command reply per platform command",
        )
        checkThat(
            commandReplyTags.zipWithNext().all { (previous, next) -> previous < next },
            "$name command replies must preserve platform FIFO order",
        )
    }

    private fun requireExactKeys(value: JsonObject, expected: Set<String>, context: String) {
        checkThat(value.values.keys == expected, "$context fields drifted: ${value.values.keys}")
    }

    private fun JsonValue.nonBlank(context: String): String = string().also {
        checkThat(it.isNotBlank(), "$context must not be blank")
    }

    private fun JsonValue.nonNegativeLong(context: String): Long = long().also {
        checkThat(it >= 0, "$context must be non-negative")
    }

    private fun JsonValue.positiveLong(context: String): Long = nonNegativeLong(context).also {
        checkThat(it > 0, "$context must be positive")
    }

    private fun JsonValue.finiteNumber(context: String): Double {
        val number = (this as? JsonNumber)?.source?.toDoubleOrNull()
            ?: error("$context must be a JSON number")
        checkThat(number.isFinite(), "$context must be finite")
        return number
    }

    private fun bootstrapManifest() {
        val rootAllowed = setOf(
            "version", "identities", "hosts", "jumpChains", "knownHosts", "appearance", "settings",
        )
        val identityAllowed = setOf("id", "name", "user")
        val hostAllowed = setOf(
            "id", "name", "address", "port", "user", "transport", "launchMode",
            "tmuxSessionName", "tags", "osHint", "sortOrder", "authenticationHint",
            "identityID", "hostKeyFingerprint", "launchCommand", "notes", "envVars",
            "startupSnippet", "portForwards",
        )
        val jumpAllowed = setOf("hostID", "jumpHostID")
        val knownHostAllowed = setOf("hostID", "fingerprint", "keyString", "firstSeen", "lastSeen")
        val appearanceAllowed = setOf(
            "colorScheme", "accent", "customAccentRGB", "monospacedFontName", "terminalFontSize",
            "chromeMaterial", "cursorStyle", "cursorBlink", "terminalThemeID",
        )
        val settingsAllowed = setOf(
            "scrollbackLines", "modifierBehavior", "bellSoundEnabled", "bellVisualEnabled",
            "bellNotificationEnabled", "accessoryBarKeys", "filesReaperDays", "filesDefaultDestination", "agentCenterEnabled",
        )
        val forwardAllowed = setOf(
            "id", "enabled", "autoStart", "localPort", "remoteHost", "remotePort", "label",
        )

        fun rejectUnknown(root: JsonObject) {
            requireAllowed(root, rootAllowed, "manifest")
            root["identities"].array().forEachIndexed { index, value ->
                requireAllowed(value.obj(), identityAllowed, "manifest.identities[$index]")
            }
            root["hosts"].array().forEachIndexed { index, value ->
                val host = value.obj()
                requireAllowed(host, hostAllowed, "manifest.hosts[$index]")
                host.optional("portForwards")?.array()?.forEachIndexed { forwardIndex, forward ->
                    requireAllowed(
                        forward.obj(),
                        forwardAllowed,
                        "manifest.hosts[$index].portForwards[$forwardIndex]",
                    )
                }
            }
            root["jumpChains"].array().forEachIndexed { index, value ->
                requireAllowed(value.obj(), jumpAllowed, "manifest.jumpChains[$index]")
            }
            root.optional("knownHosts")?.array()?.forEachIndexed { index, value ->
                requireAllowed(value.obj(), knownHostAllowed, "manifest.knownHosts[$index]")
            }
            requireAllowed(root["appearance"].obj(), appearanceAllowed, "manifest.appearance")
            requireAllowed(root["settings"].obj(), settingsAllowed, "manifest.settings")
            root["settings"].obj().optional("agentCenterEnabled")?.let { value ->
                // Swift's optional Bool also decodes JSON null as absent.
                if (value != JsonNull && value !is JsonBoolean) {
                    throw ContractError("invalidAgentCenterEnabled")
                }
            }
        }

        val canonicalBytes = vectors.resolve("bootstrap-manifest/v2/canonical.json").readBytes()
        val canonical = JsonParser(canonicalBytes.toString(StandardCharsets.UTF_8)).parse().obj()
        rejectUnknown(canonical)
        checkThat(canonical.values.keys == rootAllowed, "bootstrap canonical root field set drifted")
        checkThat(canonical["version"].long() == 2L, "bootstrap manifest version drifted")
        checkThat(canonical["hosts"].array().size == 1, "bootstrap canonical host count drifted")
        checkThat(canonicalBytes.size <= 1_048_576, "canonical manifest exceeds byte limit")

        expectCode("unknownField:manifest:password") {
            rejectUnknown(parse("bootstrap-manifest/v2/invalid-unknown-root.json"))
        }
        for ((name, expected) in listOf("true" to true, "false" to false, "absent" to null)) {
            val manifest = parse("bootstrap-manifest/v2/agent-center-$name.json")
            rejectUnknown(manifest)
            val actual = manifest["settings"].obj().optional("agentCenterEnabled")?.boolean()
            checkThat(actual == expected, "Agent Center extension $name drifted")
        }
        for (name in listOf("invalid-string", "invalid-number")) {
            expectCode("invalidAgentCenterEnabled") {
                rejectUnknown(parse("bootstrap-manifest/v2/agent-center-$name.json"))
            }
        }
        val limits = parse("bootstrap-manifest/v2/limits.json")
        val expectedLimits = mapOf(
            "maximumEncodedByteCount" to 1_048_576L,
            "maximumHostCount" to 1_000L,
            "maximumIdentityCount" to 1_000L,
            "maximumJumpChainCount" to 1_000L,
            "maximumKnownHostCount" to 1_000L,
        )
        expectedLimits.forEach { (field, expected) ->
            checkThat(limits[field].long() == expected, "bootstrap limit $field drifted")
        }
        expectCode("encodedSizeExceeded") { checkMaximum(1_048_577, 1_048_576, "encodedSizeExceeded") }
        expectCode("tooManyHosts") { checkMaximum(1_001, 1_000, "tooManyHosts") }
        expectCode("tooManyIdentities") { checkMaximum(1_001, 1_000, "tooManyIdentities") }
        expectCode("tooManyJumpChains") { checkMaximum(1_001, 1_000, "tooManyJumpChains") }
        expectCode("tooManyKnownHosts") { checkMaximum(1_001, 1_000, "tooManyKnownHosts") }
    }

    private fun requireAllowed(value: JsonObject, allowed: Set<String>, path: String) {
        val unknown = value.values.keys.minus(allowed).sorted().firstOrNull()
        if (unknown != null) throw ContractError("unknownField:$path:$unknown")
    }

    private fun publicKeyDescriptors() {
        val v1Files = listOf(
            "device-public-key/v1/ed25519-software.json",
            "device-public-key/v1/p256-secure-enclave.json",
        )
        val v2Files = listOf(
            "device-public-key/v2/ed25519-strong-hardware.json",
            "device-public-key/v2/p256-hardware-backed.json",
        )
        v1Files.forEach { relative ->
            val descriptor = parse(relative)
            checkThat(
                descriptor.values.keys == setOf("algorithm", "blob", "displayName", "fingerprint", "id", "protection"),
                "$relative v1 fields drifted",
            )
            checkThat(
                descriptor["protection"].string() in setOf("software", "secureEnclave"),
                "$relative v1 protection drifted",
            )
            validatePublicKey(descriptor, "blob")
            if (descriptor["protection"].string() == "secureEnclave") {
                checkThat(
                    descriptor["algorithm"].string() == "ecdsa-sha2-nistp256",
                    "$relative secure-enclave algorithm mismatch",
                )
            }
        }
        v2Files.forEach { relative ->
            val descriptor = parse(relative)
            checkThat(
                descriptor.values.keys == setOf("algorithm", "displayName", "fingerprint", "id", "protectionClaim", "sshBlob"),
                "$relative v2 fields drifted",
            )
            checkThat(
                descriptor["protectionClaim"].string() in setOf(
                    "softwareExportable", "platformProtected", "platformHardwareBacked",
                    "platformStrongHardware", "unknown",
                ),
                "$relative v2 protection claim drifted",
            )
            validatePublicKey(descriptor, "sshBlob")
        }
    }

    private fun validatePublicKey(descriptor: JsonObject, blobField: String) {
        UUID.fromString(descriptor["id"].string())
        val displayName = descriptor["displayName"].string()
        checkThat(
            displayName.isNotEmpty() && displayName == displayName.trim() &&
                displayName.length <= 128 && displayName.none(Char::isISOControl) &&
                displayName.none { it.code in setOf(
                    0x061c, 0x200e, 0x200f, 0x202a, 0x202b, 0x202c,
                    0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069,
                ) },
            "public-key display metadata is unsafe",
        )
        val blob = decodeBase64(descriptor[blobField].string())
        checkThat(blob.isNotEmpty() && blob.size <= 16 * 1024, "public-key SSH blob size drifted")
        val algorithm = descriptor["algorithm"].string()
        checkThat(algorithm in setOf("ssh-ed25519", "ecdsa-sha2-nistp256"), "unsupported SSH algorithm")
        val cursor = ByteCursor(blob)
        val encodedAlgorithm = cursor.readLengthPrefixed()
        checkThat(
            encodedAlgorithm.size <= 128 && encodedAlgorithm.toString(StandardCharsets.UTF_8) == algorithm,
            "SSH blob algorithm mismatch",
        )
        when (algorithm) {
            "ssh-ed25519" -> checkThat(cursor.readLengthPrefixed().size == 32, "invalid Ed25519 public key")
            "ecdsa-sha2-nistp256" -> {
                checkThat(
                    cursor.readLengthPrefixed().toString(StandardCharsets.UTF_8) == "nistp256",
                    "invalid P-256 curve name",
                )
                val point = cursor.readLengthPrefixed()
                checkThat(point.size == 65 && point[0] == 0x04.toByte(), "invalid P-256 public point")
            }
        }
        checkThat(cursor.isAtEnd, "trailing SSH public-key bytes")
        val fingerprint = "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(sha256(blob))
        checkThat(descriptor["fingerprint"].string() == fingerprint, "public-key fingerprint mismatch")
    }

    private fun enrollmentV1() {
        val canonicalKinds = linkedMapOf(
            "request.json" to "request",
            "installed.json" to "installed",
            "recorded.json" to "recorded",
            "completed.json" to "completed",
            "rejected.json" to "rejected",
            "cancelled.json" to "cancelled",
            "failed-installation.json" to "failed",
        )
        canonicalKinds.forEach { (file, expectedKind) ->
            val relative = "enrollment/v1/$file"
            val bytes = vectors.resolve(relative).readBytes()
            checkThat(bytes.isNotEmpty() && bytes.size <= 64 * 1024, "$file enrollment payload size drifted")
            val message = JsonParser(bytes.toString(StandardCharsets.UTF_8)).parse().obj()
            checkThat(message.values.keys.toList() == message.values.keys.sorted(), "$file is not canonical sorted JSON")
            validateEnrollmentMessage(message)
            checkThat(message["type"].string() == expectedKind, "$file kind drifted")
            val frame = ByteBuffer.allocate(4 + bytes.size).order(ByteOrder.BIG_ENDIAN)
                .putInt(bytes.size).put(bytes).array()
            checkThat(readU32(frame, 0) == bytes.size, "$file frame length prefix drifted")
            checkThat(frame.copyOfRange(4, frame.size).contentEquals(bytes), "$file frame payload drifted")
        }

        expectCode("unsupportedVersion") {
            validateEnrollmentMessage(parse("enrollment/v1/invalid-unsupported-version.json"))
        }

        val requester = LinearMachine(
            "ready",
            mapOf(
                ("ready" to "request") to "awaitingInstalled",
                ("awaitingInstalled" to "installed") to "awaitingCompleted",
                ("awaitingCompleted" to "completed") to "completed",
            ),
        )
        val origin = LinearMachine(
            "awaitingRequest",
            mapOf(
                ("awaitingRequest" to "request") to "awaitingInstallation",
                ("awaitingInstallation" to "installed") to "awaitingRecorded",
                ("awaitingRecorded" to "recorded") to "completed",
            ),
        )
        requester.apply("request")
        origin.apply("request")
        origin.apply("installed")
        requester.apply("installed")
        origin.apply("recorded")
        requester.apply("completed")
        checkThat(requester.state == "completed" && origin.state == "completed", "enrollment roles did not complete")
        expectCode("invalidTransition") { requester.apply("completed") }
        expectCode("invalidTransition") { origin.apply("recorded") }
    }

    private fun validateEnrollmentMessage(message: JsonObject) {
        if (message["v"].long() != 1L) throw ContractError("unsupportedVersion")
        val kind = message["type"].string()
        checkThat(
            kind in setOf("request", "installed", "recorded", "completed", "rejected", "cancelled", "failed"),
            "unknown enrollment kind",
        )
        when (kind) {
            "request" -> {
                checkThat(message.values.keys == setOf("request", "type", "v"), "request envelope fields drifted")
                val request = message["request"].obj()
                checkThat(
                    request.values.keys == setOf("hostID", "hostName", "id", "publicKey", "requestingDeviceName"),
                    "enrollment request fields drifted",
                )
                UUID.fromString(request["id"].string())
                UUID.fromString(request["hostID"].string())
                listOf(request["hostName"].string(), request["requestingDeviceName"].string()).forEach {
                    checkThat(it.isNotEmpty() && it == it.trim() && it.length <= 128 && it.none(Char::isISOControl), "unsafe enrollment display metadata")
                }
                validatePublicKey(request["publicKey"].obj(), "blob")
            }
            "failed" -> {
                checkThat(message.values.keys == setOf("enrollmentID", "failure", "type", "v"), "failed envelope fields drifted")
                checkThat(
                    message["failure"].string() in setOf(
                        "authorizationFailed", "installationFailed", "persistenceFailed", "protocolViolation",
                    ),
                    "enrollment failure code drifted",
                )
                UUID.fromString(message["enrollmentID"].string())
            }
            else -> {
                checkThat(message.values.keys == setOf("enrollmentID", "type", "v"), "$kind envelope fields drifted")
                UUID.fromString(message["enrollmentID"].string())
            }
        }
    }

    private fun legacyNearbyBootstrapV2() {
        val vector = parse("legacy-nearby-bootstrap/v2/canonical.json")
        checkThat(vector["protocolVersion"].long() == 2L, "legacy bootstrap version drifted")
        checkThat(vector["releasedAppVersion"].string() == "0.3.6", "released app-version fixture drifted")

        val origin = vector["origin"].obj()
        val recipient = vector["recipient"].obj()
        val originPrivate = decodeHex(origin["privateKeySeedHex"].string())
        val recipientPrivate = decodeHex(recipient["privateKeySeedHex"].string())
        val originPublic = decodeHex(origin["publicKeyHex"].string())
        val recipientPublic = decodeHex(recipient["publicKeyHex"].string())
        val x25519BasePoint = ByteArray(32).also { it[0] = 9 }
        checkThat(x25519(originPrivate, x25519BasePoint).contentEquals(originPublic), "legacy origin public key drifted")
        checkThat(x25519(recipientPrivate, x25519BasePoint).contentEquals(recipientPublic), "legacy recipient public key drifted")

        for ((participant, role, publicKey) in listOf(
            Triple(origin, "origin", originPublic),
            Triple(recipient, "recipient", recipientPublic),
        )) {
            val helloBytes = participant["canonicalHelloJSON"].string().toByteArray(StandardCharsets.UTF_8)
            checkMaximum(helloBytes.size, 4_096, "invalidFrame")
            requireCanonicalSortedObject(helloBytes)
            val hello = JsonParser(helloBytes.toString(StandardCharsets.UTF_8)).parse().obj()
            checkThat(hello.values.keys == setOf("appVersion", "ephemeralPublicKey", "role", "supportedVersions", "version"), "legacy hello fields drifted")
            checkThat(hello["role"].string() == role, "legacy hello role drifted")
            checkThat(hello["version"].long() == 2L, "legacy hello version drifted")
            checkThat(hello["supportedVersions"].array().map(JsonValue::long) == listOf(2L), "legacy version list drifted")
            checkThat(decodeBase64(hello["ephemeralPublicKey"].string()).contentEquals(publicKey), "legacy hello public key drifted")
        }

        val commitment = vector["commitment"].obj()
        val projectionBytes = commitment["canonicalProjectionJSON"].string().toByteArray(StandardCharsets.UTF_8)
        requireCanonicalSortedObject(projectionBytes)
        val commitmentInput = legacyLengthPrefixed("tessera/nearby-bootstrap/recipient-commitment/v2".toByteArray()) +
            legacyLengthPrefixed(projectionBytes)
        val helloDigest = sha256(commitmentInput)
        checkThat(helloDigest.contentEquals(decodeHex(commitment["helloDigestHex"].string())), "legacy commitment digest drifted")
        val commitmentBytes = commitment["canonicalJSON"].string().toByteArray(StandardCharsets.UTF_8)
        checkMaximum(commitmentBytes.size, 4_096, "invalidFrame")
        requireCanonicalSortedObject(commitmentBytes)
        val commitmentObject = JsonParser(commitmentBytes.toString(StandardCharsets.UTF_8)).parse().obj()
        checkThat(decodeBase64(commitmentObject["helloDigest"].string()).contentEquals(helloDigest), "legacy commitment payload drifted")

        val transcript = legacyLengthPrefixed("tessera/nearby-bootstrap/transcript/v2".toByteArray()) +
            ByteBuffer.allocate(2).order(ByteOrder.BIG_ENDIAN).putShort(2.toShort()).array() +
            legacyLengthPrefixed("role:origin".toByteArray()) + legacyLengthPrefixed(originPublic) +
            legacyLengthPrefixed("role:recipient".toByteArray()) + legacyLengthPrefixed(recipientPublic)
        checkThat(transcript.contentEquals(decodeHex(vector["transcriptHex"].string())), "legacy transcript bytes drifted")
        val transcriptHash = sha256(transcript)
        checkThat(transcriptHash.contentEquals(decodeHex(vector["transcriptHashHex"].string())), "legacy transcript hash drifted")

        val sharedFromOrigin = x25519(originPrivate, recipientPublic)
        val sharedFromRecipient = x25519(recipientPrivate, originPublic)
        checkThat(sharedFromOrigin.contentEquals(sharedFromRecipient), "legacy X25519 peers disagreed")
        val material = mapOf(
            "originToRecipientKeyHex" to hkdf(sharedFromOrigin, transcriptHash, "tessera/nearby-bootstrap/key/origin-to-recipient/v1", 32),
            "recipientToOriginKeyHex" to hkdf(sharedFromOrigin, transcriptHash, "tessera/nearby-bootstrap/key/recipient-to-origin/v1", 32),
            "originToRecipientNonceHex" to hkdf(sharedFromOrigin, transcriptHash, "tessera/nearby-bootstrap/nonce/origin-to-recipient/v1", 12),
            "recipientToOriginNonceHex" to hkdf(sharedFromOrigin, transcriptHash, "tessera/nearby-bootstrap/nonce/recipient-to-origin/v1", 12),
        )
        val directional = vector["directionalMaterial"].obj()
        material.forEach { (field, bytes) ->
            checkThat(bytes.contentEquals(decodeHex(directional[field].string())), "legacy $field drifted")
        }
        val sasBytes = hkdf(sharedFromOrigin, transcriptHash, "tessera/nearby-bootstrap/sas/v1", 8)
        checkThat(sasBytes.contentEquals(decodeHex(vector["sasBytesHex"].string())), "legacy SAS bytes drifted")
        val sasDigits = BigInteger(1, sasBytes).mod(BigInteger.valueOf(1_000_000)).toString().padStart(6, '0')
        checkThat(sasDigits == vector["sasDigits"].string(), "legacy SAS digits drifted")

        val fullTransfer = vector["fullTransfer"].obj()
        val canonicalPayloadByKind = mapOf(
            "recipientPublicKey" to fullTransfer["recipientPublicKeyCanonicalJSON"].string(),
            "manifest" to fullTransfer["manifestCanonicalJSON"].string(),
            "importAcceptance" to fullTransfer["importAcceptanceCanonicalJSON"].string(),
            "grantReceipt" to fullTransfer["grantReceiptCanonicalJSON"].string(),
            "completionAcknowledgement" to fullTransfer["completionAcknowledgementCanonicalJSON"].string(),
        )
        canonicalPayloadByKind.values.forEach { requireCanonicalSortedObject(it.toByteArray(StandardCharsets.UTF_8)) }
        val acceptance = JsonParser(canonicalPayloadByKind.getValue("importAcceptance")).parse().obj()
        checkThat(
            decodeBase64(acceptance["manifestHash"].string()).contentEquals(
                sha256(canonicalPayloadByKind.getValue("manifest").toByteArray(StandardCharsets.UTF_8)),
            ),
            "legacy manifest acceptance hash drifted",
        )
        val completion = JsonParser(canonicalPayloadByKind.getValue("completionAcknowledgement")).parse().obj()
        checkThat(
            decodeBase64(completion["grantReceiptHash"].string()).contentEquals(
                sha256(canonicalPayloadByKind.getValue("grantReceipt").toByteArray(StandardCharsets.UTF_8)),
            ),
            "legacy grant receipt hash drifted",
        )

        val fullFrames = fullTransfer["frames"].array().map(JsonValue::obj)
        checkThat(fullFrames.size == 6, "legacy full-transfer frame inventory drifted")
        val expectedKinds = listOf(
            "recipientPublicKey", "originAuthorization", "manifest",
            "importAcceptance", "grantReceipt", "completionAcknowledgement",
        )
        checkThat(fullFrames.map { it["kind"].string() } == expectedKinds, "legacy full-transfer order drifted")
        fullFrames.forEach { frame ->
            for (field in listOf("frameHex", "alternateFrameHex")) {
                val opened = openLegacyFrame(frame[field].string(), material, transcriptHash)
                checkThat(opened.values.keys == setOf("kind", "payload"), "legacy envelope fields drifted")
                val kind = frame["kind"].string()
                checkThat(opened["kind"].string() == kind, "legacy encrypted kind drifted")
                val payload = decodeBase64(opened["payload"].string())
                if (kind == "originAuthorization") {
                    checkThat(payload.isEmpty(), "legacy authorization proof is not empty")
                } else {
                    checkThat(
                        payload.contentEquals(canonicalPayloadByKind.getValue(kind).toByteArray(StandardCharsets.UTF_8)),
                        "legacy $kind payload drifted",
                    )
                }
            }
        }

        vector["frames"].array().map(JsonValue::obj).forEach { frame ->
            for (field in listOf("frameHex", "alternateFrameHex")) {
                val opened = openLegacyFrame(frame[field].string(), material, transcriptHash)
                val expectedKind = if (frame["name"].string().contains("sas-match")) "sasDecision" else "test"
                checkThat(opened["kind"].string() == expectedKind, "legacy compatibility frame kind drifted")
            }
        }
        expectCode("invalidFrame") { checkMaximum(4_097, 4_096, "invalidFrame") }
        expectCode("invalidFrame") { checkMaximum(65_537, 65_536, "invalidFrame") }
    }

    private fun openLegacyFrame(
        frameHex: String,
        material: Map<String, ByteArray>,
        transcriptHash: ByteArray,
    ): JsonObject {
        val frame = decodeHex(frameHex)
        checkMaximum(frame.size, 65_536, "invalidFrame")
        checkThat(frame.size > 42, "legacy encrypted frame is truncated")
        checkThat(frame.copyOfRange(0, 4).toString(StandardCharsets.US_ASCII) == "TBCH", "legacy frame magic drifted")
        checkThat(frame[4].toInt() and 0xff == 1, "legacy frame version drifted")
        val direction = frame[5].toInt() and 0xff
        checkThat(direction == 1 || direction == 2, "legacy frame direction drifted")
        val sequence = readU64(frame, 6)
        val key = material.getValue(if (direction == 1) "originToRecipientKeyHex" else "recipientToOriginKeyHex")
        val baseNonce = material.getValue(if (direction == 1) "originToRecipientNonceHex" else "recipientToOriginNonceHex")
        val expectedNonce = nonceForSequence(baseNonce, sequence)
        checkThat(frame.copyOfRange(14, 26).contentEquals(expectedNonce), "legacy frame nonce/sequence drifted")
        val plaintext = openChaCha20Poly1305(
            key = key,
            nonce = expectedNonce,
            ciphertextAndTag = frame.copyOfRange(26, frame.size),
            authenticatedData = frame.copyOfRange(0, 14) + transcriptHash,
        )
        return JsonParser(plaintext.toString(StandardCharsets.UTF_8)).parse().obj()
    }

    private fun pairingDeterminism() {
        val vector = parse("pairing/v1/purpose-bound-optical.json")
        checkThat(vector["vector"].string() == "tessera-pairing-v1-purpose-bound-optical", "pairing vector ID drifted")
        val offerBytes = decodeBase64(vector["offerBase64"].string())
        val commitmentBytes = decodeBase64(vector["commitmentBase64"].string())
        val originHelloBytes = decodeBase64(vector["originHelloBase64"].string())
        val recipientHelloBytes = decodeBase64(vector["recipientHelloBase64"].string())
        listOf(offerBytes, commitmentBytes, originHelloBytes, recipientHelloBytes).forEach {
            requireCanonicalSortedObject(it)
        }

        val schema = parse("pairing/v1/offer.schema.json")
        checkThat(!schema["additionalProperties"].boolean(), "pairing offer must reject unknown fields")
        val schemaRequired = schema["required"].array().map(JsonValue::string).toSet()
        val offer = JsonParser(offerBytes.toString(StandardCharsets.UTF_8)).parse().obj()
        checkThat(offer.values.keys.containsAll(schemaRequired), "pairing offer misses a required field")
        checkThat(offer.values.keys.all { it in schema["properties"].obj().values.keys }, "pairing offer has an unknown field")
        checkThat(offer["version"].long() == 1L, "pairing offer version drifted")
        checkThat(offer["originRole"].string() == "origin", "pairing origin role drifted")
        checkThat(offer["purpose"].string() == "continue", "pairing purpose binding drifted")
        checkThat(offer["endpointCandidates"].array().size <= 8, "pairing endpoint limit exceeded")

        val transcript = decodeHex(vector["transcriptHex"].string())
        val transcriptHash = sha256(transcript)
        checkThat(transcriptHash.contentEquals(decodeHex(vector["transcriptHashHex"].string())), "pairing transcript SHA-256 drifted")
        val cursor = ByteCursor(transcript)
        checkThat(cursor.readLengthPrefixed().toString(StandardCharsets.UTF_8) == "tessera/pairing/transcript/v1", "transcript domain label drifted")
        checkThat(cursor.readU16() == 1, "transcript version drifted")
        checkThat(cursor.readLengthPrefixed().contentEquals(offerBytes), "transcript offer bytes drifted")
        checkThat(cursor.readLengthPrefixed().contentEquals(commitmentBytes), "transcript commitment bytes drifted")
        checkThat(cursor.readLengthPrefixed().contentEquals(originHelloBytes), "transcript origin hello bytes drifted")
        checkThat(cursor.readLengthPrefixed().contentEquals(recipientHelloBytes), "transcript recipient hello bytes drifted")
        val proofOffset = cursor.offset
        val opticalProof = cursor.readLengthPrefixed()
        checkThat(cursor.isAtEnd, "trailing pairing transcript bytes")
        val opticalSecret = decodeHex(vector["opticalSecretHex"].string())
        val proofInput = lengthPrefixed("tessera/pairing/optical-binding/v1".toByteArray()) +
            lengthPrefixed(transcript.copyOfRange(0, proofOffset))
        checkThat(opticalProof.contentEquals(hmacSha256(opticalSecret, proofInput)), "optical transcript proof drifted")

        val originPrivate = decodeHex(vector["originPrivateKeyHex"].string())
        val recipientPrivate = decodeHex(vector["recipientPrivateKeyHex"].string())
        val originPublic = decodeBase64(JsonParser(originHelloBytes.toString(StandardCharsets.UTF_8)).parse().obj()["ephemeralPublicKey"].string())
        val recipientPublic = decodeBase64(JsonParser(recipientHelloBytes.toString(StandardCharsets.UTF_8)).parse().obj()["ephemeralPublicKey"].string())
        val sharedFromOrigin = x25519(originPrivate, recipientPublic)
        val sharedFromRecipient = x25519(recipientPrivate, originPublic)
        checkThat(sharedFromOrigin.contentEquals(sharedFromRecipient), "X25519 peers derived different secrets")

        val outputs = mapOf(
            "originToRecipientKeyHex" to hkdf(sharedFromOrigin, transcriptHash, "tessera/pairing/v1/key/origin-to-recipient", 32),
            "recipientToOriginKeyHex" to hkdf(sharedFromOrigin, transcriptHash, "tessera/pairing/v1/key/recipient-to-origin", 32),
            "originToRecipientNonceHex" to hkdf(sharedFromOrigin, transcriptHash, "tessera/pairing/v1/nonce/origin-to-recipient", 12),
            "recipientToOriginNonceHex" to hkdf(sharedFromOrigin, transcriptHash, "tessera/pairing/v1/nonce/recipient-to-origin", 12),
        )
        outputs.forEach { (field, actual) ->
            checkThat(actual.contentEquals(decodeHex(vector[field].string())), "$field HKDF output drifted")
        }
        val sasBytes = hkdf(sharedFromOrigin, transcriptHash, "tessera/pairing/v1/sas", 8)
        val sas = BigInteger(1, sasBytes).mod(BigInteger.valueOf(1_000_000)).toString().padStart(6, '0')
        checkThat(sas == vector["sas"].string(), "pairing SAS derivation drifted")
        checkThat(sas.matches(Regex("[0-9]{6}")), "pairing SAS is not six digits")

        val frame = decodeHex(vector["transactionFrameHex"].string())
        checkThat(frame.copyOfRange(0, 4).toString(StandardCharsets.US_ASCII) == "TPF1", "pairing frame magic drifted")
        checkThat(frame[4].toInt() and 0xff == 1, "pairing frame version drifted")
        checkThat(frame[5].toInt() and 0xff == 1, "pairing frame direction drifted")
        checkThat(readU64(frame, 6) == 1L, "pairing frame sequence drifted")
        val declaredLength = readU32(frame, 14)
        checkThat(frame.size == 18 + declaredLength, "pairing frame length mismatch")
        val expectedNonce = nonceForSequence(outputs.getValue("originToRecipientNonceHex"), 1L)
        checkThat(frame.copyOfRange(18, 30).contentEquals(expectedNonce), "pairing frame nonce/sequence relation drifted")
        val plaintext = openChaCha20Poly1305(
            key = outputs.getValue("originToRecipientKeyHex"),
            nonce = expectedNonce,
            ciphertextAndTag = frame.copyOfRange(30, frame.size),
            authenticatedData = frame.copyOfRange(0, 18) + transcriptHash,
        )
        val envelope = JsonParser(plaintext.toString(StandardCharsets.UTF_8)).parse().obj()
        checkThat(
            envelope.values.keys.toList() == listOf("kind", "payload"),
            "pairing transaction envelope is not canonical",
        )
        checkThat(envelope["kind"].string() == "transactionMessage", "pairing frame kind drifted")
        checkThat(
            decodeBase64(envelope["payload"].string())
                .contentEquals("continuation-vector".toByteArray(StandardCharsets.UTF_8)),
            "pairing frame plaintext drifted",
        )
    }

    private fun pairingRejections() {
        val vector = parse("pairing/v1/rejections.json")
        val expected = vector["expectedErrors"].obj()
        checkThat(vector["handshakeExpiryBoundary"].long() == 1_700_000_060L, "handshake expiry boundary drifted")
        checkThat(vector["sessionExpiryBoundary"].long() == 1_700_000_300L, "session expiry boundary drifted")
        expectCode(expected["expiredTransition"].string()) {
            requireFresh(vector["handshakeExpiryBoundary"].long(), 1_700_000_060L)
        }
        expectCode(expected["downgrade"].string()) {
            requireHighestCommon(
                selected = vector["downgradedSelectedTransactionVersion"].long().toInt(),
                local = listOf(1, 2),
                peer = listOf(1, 2),
            )
        }
        val machine = PairingEnvelopeMachine(expiresAt = vector["sessionExpiryBoundary"].long())
        machine.localDecision(true, 1_700_000_000L)
        machine.peerDecision(true, 1_700_000_000L)
        machine.localCompletion(1_700_000_000L)
        machine.peerCompletion(1_700_000_000L)
        checkThat(machine.complete, "pairing completion model did not become terminal")
        checkThat(vector["postCompletionEnvelopeKind"].string() == "abort", "post-completion vector kind drifted")
        expectCode(expected["postCompletionTraffic"].string()) {
            machine.abort(1_700_000_000L)
        }
        val expiring = PairingEnvelopeMachine(expiresAt = vector["sessionExpiryBoundary"].long())
        expectCode(expected["expiredTransition"].string()) {
            expiring.localDecision(true, vector["sessionExpiryBoundary"].long())
        }
    }

    private fun continuationTransaction() {
        val vector = parse("continuation-transaction/v1/canonical.json")
        val kinds = mapOf(
            "descriptorMessageBase64" to "descriptor",
            "acceptanceMessageBase64" to "accepted",
            "connectionMessageBase64" to "connected",
            "completionAcknowledgementMessageBase64" to "completionAcknowledgement",
        )
        kinds.forEach { (field, expectedKind) ->
            val message = JsonParser(decodeBase64(vector[field].string()).toString(StandardCharsets.UTF_8)).parse().obj()
            checkThat(message.values.keys == setOf("kind", "payload", "transactionID", "version"), "$field envelope fields drifted")
            checkThat(message["version"].long() == 1L, "$field version drifted")
            checkThat(message["transactionID"].string() == "11111111-2222-3333-4444-555555555555", "$field transaction ID drifted")
            checkThat(message["kind"].string() == expectedKind, "$field kind drifted")
            checkThat(decodeBase64(message["payload"].string()).isNotEmpty(), "$field payload is empty")
        }

        val origin = LinearMachine(
            "readyToSend",
            mapOf(
                ("readyToSend" to "descriptor") to "awaitingAcceptance",
                ("awaitingAcceptance" to "accepted") to "awaitingConnection",
                ("awaitingConnection" to "connected") to "completed",
            ),
        )
        val recipient = LinearMachine(
            "awaitingDescriptor",
            mapOf(
                ("awaitingDescriptor" to "descriptor") to "awaitingDurableAcceptance",
                ("awaitingDurableAcceptance" to "accepted") to "awaitingConnection",
                ("awaitingConnection" to "connected") to "awaitingCompletionAcknowledgement",
                ("awaitingCompletionAcknowledgement" to "completionAcknowledgement") to "completed",
            ),
        )
        origin.apply("descriptor")
        recipient.apply("descriptor")
        recipient.apply("accepted")
        origin.apply("accepted")
        recipient.apply("connected")
        origin.apply("connected")
        recipient.apply("completionAcknowledgement")
        checkThat(origin.state == "completed", "continuation origin did not complete")
        checkThat(recipient.state == "completed", "continuation recipient did not complete")
        expectCode("invalidTransition") { origin.apply("completionAcknowledgement") }
        val rejections = parse("continuation-transaction/v1/rejections.json")
        val errors = rejections["expectedErrors"].obj()
        rejections["invalidAbortCodes"].array().map(JsonValue::string).forEach { code ->
            expectCode(errors["invalidAbortCode"].string()) { validateAbortCode(code) }
        }
        validateAbortCode(rejections["validAbortCode"].string())
        expectCode(errors["terminalMutation"].string()) { origin.abort(rejections["validAbortCode"].string()) }
        val aborted = LinearMachine("awaitingDescriptor", emptyMap())
        aborted.abort(rejections["validAbortCode"].string())
        expectCode(errors["terminalMutation"].string()) { aborted.abort(rejections["validAbortCode"].string()) }
    }

    private fun bootstrapTransaction(version: Int) {
        val vector = parse("bootstrap-transaction/v$version/receipts.json")
        val expectedKinds = mapOf(
            "importAcceptanceMessageBase64" to "importAcceptance",
            "grantReceiptMessageBase64" to "grantReceipt",
            "grantAcknowledgementMessageBase64" to "grantAcknowledgement",
            "completionMessageBase64" to "completion",
        )
        expectedKinds.forEach { (field, expectedKind) ->
            val message = JsonParser(decodeBase64(vector[field].string()).toString(StandardCharsets.UTF_8)).parse().obj()
            checkThat(message.values.keys == setOf("body", "kind", "transactionID", "version"), "$field envelope fields drifted")
            checkThat(message["version"].long() == version.toLong(), "$field version drifted")
            val bytes = decodeBase64(vector[field].string())
            requireCanonicalSortedObject(bytes)
            val expectedBytes = "{\"body\":\"${message["body"].string()}\",\"kind\":\"$expectedKind\",\"transactionID\":\"${message["transactionID"].string()}\",\"version\":$version}"
            checkThat(bytes.toString(StandardCharsets.UTF_8) == expectedBytes, "$field is not canonical")
            if (version == 2) {
                val released = parse("bootstrap-transaction/v1/receipts.json")
                val oldMessage = JsonParser(decodeBase64(released[field].string()).toString(StandardCharsets.UTF_8)).parse().obj()
                checkThat(message.values.filterKeys { it != "version" } == oldMessage.values.filterKeys { it != "version" }, "$field v2 changed frozen v1 bodies")
            }
            checkThat(message["transactionID"].string() == "11111111-2222-3333-4444-555555555555", "$field transaction ID drifted")
            checkThat(message["kind"].string() == expectedKind, "$field kind drifted")
            val body = JsonParser(decodeBase64(message["body"].string()).toString(StandardCharsets.UTF_8)).parse().obj()
            checkThat(body.values.isNotEmpty(), "$field body is empty")
        }

        val origin = LinearMachine(
            "awaitingImportAcceptance",
            mapOf(
                ("awaitingImportAcceptance" to "importAcceptance") to "awaitingGrantReceipt",
                ("awaitingGrantReceipt" to "grantReceipt") to "awaitingGrantAcknowledgement",
                ("awaitingGrantAcknowledgement" to "grantAcknowledgement") to "awaitingCompletion",
                ("awaitingCompletion" to "completion") to "completed",
            ),
        )
        expectedKinds.values.forEach(origin::apply)
        checkThat(origin.state == "completed", "bootstrap transaction did not complete")

        val rejections = parse("bootstrap-transaction/v$version/rejections.json")
        val errors = rejections["expectedErrors"].obj()
        checkThat(errors["changedRoute"].string() == "authorizationScopeMismatch", "bootstrap route rejection drifted")
        checkThat(errors["changedHostSet"].string() == "manifestMismatch", "bootstrap host-set rejection drifted")
        checkThat(errors["incompleteGrantReceipt"].string() == "invalidGrantReceipt", "bootstrap receipt rejection drifted")
        expectCode("invalidAbort") { validateAbortCode(rejections["invalidAbortCode"].string()) }
        validateAbortCode(rejections["validAbortCode"].string())
        expectCode(errors["terminalMutation"].string()) { origin.abort(rejections["validAbortCode"].string()) }

        val aborted = LinearMachine("awaitingRecipientPublicKey", emptyMap())
        aborted.abort(rejections["validAbortCode"].string())
        expectCode(errors["terminalMutation"].string()) { aborted.apply("recipientPublicKey") }

        val optional = parse("bootstrap-transaction/v$version/optional-transfer-rejections.json")
        checkThat(
            optional["optionalCategories"].array().map(JsonValue::string).toSet() == setOf(
                "launchCommands", "notes", "environmentVariables", "startupSnippets", "trustedHostKeys",
            ),
            "bootstrap optional-transfer category set drifted",
        )
        val optionalErrors = optional["expectedErrors"].obj()
        checkThat(
            optionalErrors.values.values.map(JsonValue::string).toSet() ==
                setOf("optionalTransferAuthorizationRequired", "invalidTransition"),
            "bootstrap optional-transfer rejection codes drifted",
        )
    }

    private fun sessionChallenges() {
        val vector = parse("session/v1/challenges.json")
        val limits = vector["limits"].obj()
        checkThat(limits["maximumLifetimeSeconds"].long() == 60L, "challenge lifetime limit drifted")
        checkThat(limits["maximumEncodedBytes"].long() == 4_096L, "challenge encoded limit drifted")
        checkThat(limits["maximumHostBytes"].long() == 255L, "challenge host limit drifted")
        checkThat(limits["maximumFingerprintBytes"].long() == 256L, "challenge fingerprint limit drifted")
        checkThat(limits["maximumHintBytes"].long() == 1_024L, "challenge hint limit drifted")
        checkThat(limits["maximumCodeBytes"].long() == 64L, "challenge code limit drifted")

        val valid = vector["validOwnerAuthorization"].obj()
        UUID.fromString(valid["challengeID"].string())
        UUID.fromString(valid["sessionID"].string())
        UUID.fromString(valid["attemptID"].string())
        val now = valid["now"].long()
        val expiresAt = valid["expiresAt"].long()
        val reason = valid["reasonCode"].string()
        validateChallenge(now, expiresAt, reason, limits)

        val machine = ChallengeMachine(
            sessionID = valid["sessionID"].string(),
            attemptID = valid["attemptID"].string(),
            policyGeneration = valid["policyGeneration"].long(),
            expiresAt = expiresAt,
        )
        vector["rejections"].array().forEach { raw ->
            val rejection = raw.obj()
            when (rejection["case"].string()) {
                "zeroLifetime", "overlongLifetime" -> expectCode(rejection["expectedError"].string()) {
                    validateChallenge(now, rejection["expiresAt"].long(), reason, limits)
                }
                "controlCharacter" -> expectCode(rejection["expectedError"].string()) {
                    validateChallenge(now, expiresAt, rejection["reasonCode"].string(), limits)
                }
                "staleSessionChallenge" -> expectCode(rejection["expectedError"].string()) {
                    machine.acceptChallenge("44444444-4444-4444-4444-444444444444")
                }
                "stalePolicyResponse" -> expectCode(rejection["expectedError"].string()) {
                    machine.consume(
                        attemptID = valid["attemptID"].string(),
                        policyGeneration = rejection["responsePolicyGeneration"].long(),
                        now = now,
                    )
                }
                "secondConsumption" -> {
                    machine.consume(
                        attemptID = valid["attemptID"].string(),
                        policyGeneration = valid["policyGeneration"].long(),
                        now = now,
                    )
                    expectCode(rejection["expectedError"].string()) {
                        machine.consume(
                            attemptID = valid["attemptID"].string(),
                            policyGeneration = valid["policyGeneration"].long(),
                            now = now,
                        )
                    }
                }
                else -> error("unknown challenge rejection case")
            }
        }
    }

    private fun validateChallenge(
        now: Long,
        expiresAt: Long,
        code: String,
        limits: JsonObject,
    ) {
        val lifetime = expiresAt - now
        if (lifetime <= 0 || lifetime > limits["maximumLifetimeSeconds"].long()) {
            throw ContractError("invalidLifetime")
        }
        if (code.isEmpty() || code.toByteArray(StandardCharsets.UTF_8).size > limits["maximumCodeBytes"].long() ||
            code.any(Char::isISOControl)
        ) {
            throw ContractError("invalidDisplayMetadata")
        }
    }

    private fun expectCode(expected: String, body: () -> Unit) {
        assertions += 1
        try {
            body()
        } catch (error: ContractError) {
            check(error.code == expected) { "expected $expected, got ${error.code}" }
            return
        }
        error("expected rejection $expected")
    }

    private fun checkMaximum(actual: Int, maximum: Int, code: String) {
        if (actual > maximum) throw ContractError(code)
    }
}

private class LinearMachine(
    initial: String,
    private val transitions: Map<Pair<String, String>, String>,
) {
    var state: String = initial
        private set

    fun apply(event: String) {
        if (state in setOf("completed", "aborted")) throw ContractError("invalidTransition")
        state = transitions[state to event] ?: throw ContractError("invalidTransition")
    }

    fun abort(code: String) {
        validateAbortCode(code)
        if (state in setOf("completed", "aborted")) throw ContractError("invalidTransition")
        state = "aborted"
    }
}

private class PairingEnvelopeMachine(private val expiresAt: Long) {
    private var localDecision: Boolean? = null
    private var peerDecision: Boolean? = null
    private var localCompletion = false
    private var peerCompletion = false
    private var aborted = false

    val complete: Boolean get() = localCompletion && peerCompletion && !aborted

    fun localDecision(matches: Boolean, now: Long) {
        requireNotTerminal(now)
        if (localDecision != null) throw ContractError("unexpectedMessageOrder")
        localDecision = matches
    }

    fun peerDecision(matches: Boolean, now: Long) {
        requireNotTerminal(now)
        if (peerDecision != null) throw ContractError("unexpectedMessageOrder")
        peerDecision = matches
    }

    fun localCompletion(now: Long) {
        requireReady(now)
        if (localCompletion) throw ContractError("unexpectedMessageOrder")
        localCompletion = true
    }

    fun peerCompletion(now: Long) {
        requireNotTerminal(now)
        if (localDecision != true || peerDecision != true || peerCompletion) {
            throw ContractError("unexpectedMessageOrder")
        }
        peerCompletion = true
    }

    fun abort(now: Long) {
        requireNotTerminal(now)
        aborted = true
    }

    private fun requireReady(now: Long) {
        requireNotTerminal(now)
        if (localDecision != true || peerDecision != true || localCompletion || peerCompletion) {
            throw ContractError("unexpectedMessageOrder")
        }
    }

    private fun requireNotTerminal(now: Long) {
        if (now >= expiresAt) throw ContractError("offerExpired")
        if (aborted || complete) throw ContractError("unexpectedMessageOrder")
    }
}

private class ChallengeMachine(
    private val sessionID: String,
    private val attemptID: String,
    private val policyGeneration: Long,
    private val expiresAt: Long,
) {
    private var consumed = false

    fun acceptChallenge(sessionID: String) {
        if (sessionID != this.sessionID) throw ContractError("staleSession")
    }

    fun consume(attemptID: String, policyGeneration: Long, now: Long) {
        if (consumed) throw ContractError("alreadyConsumed")
        if (attemptID != this.attemptID) throw ContractError("staleAttempt")
        if (policyGeneration != this.policyGeneration) throw ContractError("stalePolicy")
        if (now >= expiresAt) throw ContractError("expired")
        consumed = true
    }
}

private fun validateAbortCode(code: String) {
    if (code.isEmpty() || code.toByteArray().size > 128 || code.any(Char::isISOControl)) {
        throw ContractError("invalidAbort")
    }
}

private fun requireFresh(now: Long, expiresAt: Long) {
    if (now >= expiresAt) throw ContractError("offerExpired")
}

private fun requireHighestCommon(selected: Int, local: List<Int>, peer: List<Int>) {
    val highest = local.intersect(peer.toSet()).maxOrNull() ?: throw ContractError("noCommonTransactionVersion")
    if (selected != highest) throw ContractError("downgradeDetected")
}

private fun requireCanonicalSortedObject(bytes: ByteArray) {
    val objectValue = JsonParser(bytes.toString(StandardCharsets.UTF_8)).parse().obj()
    check(objectValue.values.keys.toList() == objectValue.values.keys.sorted()) {
        "canonical JSON object keys are not sorted"
    }
}

private fun decodeBase64(value: String): ByteArray {
    val result = try {
        Base64.getDecoder().decode(value)
    } catch (error: IllegalArgumentException) {
        throw IllegalStateException("invalid base64", error)
    }
    check(Base64.getEncoder().encodeToString(result) == value) { "non-canonical base64" }
    return result
}

private fun decodeHex(value: String): ByteArray {
    check(value.length % 2 == 0 && value.matches(Regex("[0-9a-f]*"))) { "invalid lowercase hex" }
    return ByteArray(value.length / 2) { index -> value.substring(index * 2, index * 2 + 2).toInt(16).toByte() }
}

private fun sha256(value: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(value)

private fun hmacSha256(key: ByteArray, value: ByteArray): ByteArray {
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(key, "HmacSHA256"))
    return mac.doFinal(value)
}

private fun hkdf(
    inputKeyMaterial: ByteArray,
    salt: ByteArray,
    info: String,
    outputByteCount: Int,
): ByteArray {
    val pseudoRandomKey = hmacSha256(salt, inputKeyMaterial)
    val output = ByteArrayOutputStream()
    var previous = ByteArray(0)
    var counter = 1
    while (output.size() < outputByteCount) {
        previous = hmacSha256(
            pseudoRandomKey,
            previous + info.toByteArray(StandardCharsets.UTF_8) + byteArrayOf(counter.toByte()),
        )
        output.write(previous)
        counter += 1
    }
    return output.toByteArray().copyOf(outputByteCount)
}

private fun x25519(privateScalar: ByteArray, peerPublicUCoordinate: ByteArray): ByteArray {
    check(privateScalar.size == 32 && peerPublicUCoordinate.size == 32) { "X25519 values must be 32 bytes" }
    val parameters = NamedParameterSpec.X25519
    val factory = KeyFactory.getInstance("XDH")
    val privateKey = factory.generatePrivate(XECPrivateKeySpec(parameters, privateScalar))
    val publicInteger = BigInteger(1, peerPublicUCoordinate.reversedArray())
    val publicKey = factory.generatePublic(XECPublicKeySpec(parameters, publicInteger))
    val agreement = KeyAgreement.getInstance("XDH")
    agreement.init(privateKey)
    agreement.doPhase(publicKey, true)
    return agreement.generateSecret()
}

private fun openChaCha20Poly1305(
    key: ByteArray,
    nonce: ByteArray,
    ciphertextAndTag: ByteArray,
    authenticatedData: ByteArray,
): ByteArray {
    check(key.size == 32) { "ChaCha20 key must be 32 bytes" }
    check(nonce.size == 12) { "ChaCha20-Poly1305 nonce must be 12 bytes" }
    check(ciphertextAndTag.size >= 16) { "ChaCha20-Poly1305 payload is missing its tag" }
    val cipher = Cipher.getInstance("ChaCha20-Poly1305")
    cipher.init(
        Cipher.DECRYPT_MODE,
        SecretKeySpec(key, "ChaCha20"),
        IvParameterSpec(nonce),
    )
    cipher.updateAAD(authenticatedData)
    return cipher.doFinal(ciphertextAndTag)
}

private fun lengthPrefixed(value: ByteArray): ByteArray =
    ByteBuffer.allocate(4 + value.size).order(ByteOrder.BIG_ENDIAN).putInt(value.size).put(value).array()

private fun legacyLengthPrefixed(value: ByteArray): ByteArray {
    check(value.size <= 65_535) { "legacy length-prefixed value is too large" }
    return ByteBuffer.allocate(2 + value.size).order(ByteOrder.BIG_ENDIAN)
        .putShort(value.size.toShort()).put(value).array()
}

private fun readU32(bytes: ByteArray, offset: Int): Int =
    ByteBuffer.wrap(bytes, offset, 4).order(ByteOrder.BIG_ENDIAN).int

private fun readU64(bytes: ByteArray, offset: Int): Long =
    ByteBuffer.wrap(bytes, offset, 8).order(ByteOrder.BIG_ENDIAN).long

private fun nonceForSequence(base: ByteArray, sequence: Long): ByteArray {
    check(base.size == 12) { "nonce base must be 12 bytes" }
    val result = base.copyOf()
    val sequenceBytes = ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN).putLong(sequence).array()
    for (index in sequenceBytes.indices) result[4 + index] = (result[4 + index].toInt() xor sequenceBytes[index].toInt()).toByte()
    return result
}

private class ByteCursor(private val bytes: ByteArray) {
    var offset: Int = 0
        private set
    val isAtEnd: Boolean get() = offset == bytes.size

    fun readU16(): Int {
        check(offset + 2 <= bytes.size) { "truncated u16" }
        val result = ByteBuffer.wrap(bytes, offset, 2).order(ByteOrder.BIG_ENDIAN).short.toInt() and 0xffff
        offset += 2
        return result
    }

    fun readLengthPrefixed(): ByteArray {
        check(offset + 4 <= bytes.size) { "truncated length prefix" }
        val length = readU32(bytes, offset)
        offset += 4
        check(length >= 0 && offset + length <= bytes.size) { "invalid length-prefixed value" }
        val result = bytes.copyOfRange(offset, offset + length)
        offset += length
        return result
    }
}

fun main(arguments: Array<String>) {
    check(arguments.size == 1) { "usage: kotlin-conformance <ProtocolVectors directory>" }
    val vectors = Path.of(arguments[0]).toAbsolutePath().normalize()
    check(Files.isDirectory(vectors)) { "ProtocolVectors directory not found: $vectors" }
    Conformance(vectors).run()
}
