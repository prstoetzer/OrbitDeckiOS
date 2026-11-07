import Foundation

/// Current ARRL DXCC numerical entity codes and CardSat representative
/// coordinates. Coordinates are stored east-positive, matching OrbitDeck.
/// Deleted entities intentionally have no entry.
struct DXCCNumericEntity: Identifiable, Hashable, Sendable {
    let code: Int
    let latitude: Double
    let longitude: Double
    var id: Int { code }
}

enum DXCCNumericData {
    /// Exact current-entity coordinate roster from CardSat `dxcc_geo.h`.
    /// The compact source format is code, latitude*100, longitude*100.
    private static let raw = """
1,4435,-7875
3,3470,6580
4,-1045,5667
5,6013,2037
6,6140,-14887
7,4100,2000
9,-1432,-17078
10,-3785,7753
11,1237,9278
12,1823,-6300
13,-9000,0
14,4040,4490
15,5588,8408
16,-5162,16762
17,1567,-6360
18,4045,4737
20,0,-17600
21,3960,295
22,745,13453
24,-5442,338
27,5400,2800
29,2832,-1585
31,-283,-17172
32,3590,-527
33,-732,7242
34,-4385,-17648
35,-1048,10563
36,1028,-10922
37,552,-8705
38,-1215,9682
40,3523,2478
41,-4642,5175
43,1808,-6788
45,3617,2793
46,268,11332
47,-2710,-10937
48,180,-15735
49,170,1033
50,2132,-10023
51,1500,3900
52,5900,2500
53,900,3900
54,5365,4137
56,-385,-3243
60,2425,-7600
61,8068,4992
62,1318,-5953
63,400,-5300
64,3232,-6473
65,1833,-6475
66,1697,-8867
69,1932,-8122
70,2150,-8000
71,-78,-9103
72,1913,-7068
74,1400,-8900
75,4200,4500
76,1550,-9030
77,1213,-6168
78,1902,-7218
79,1613,-6167
80,1500,-8700
82,1820,-7747
84,1470,-6103
86,1288,-8505
88,900,-8000
89,2177,-7175
90,1038,-6128
91,1253,-6998
94,1707,-6180
95,1543,-6135
96,1675,-6218
97,1387,-6100
98,1323,-6120
99,-1155,4728
100,-3250,-6213
103,1337,14470
104,-1700,-6500
105,2000,-7500
106,4945,-258
107,1100,-1068
108,-1000,-5300
109,1202,-1480
110,2112,-15748
111,-5308,7350
112,-3000,-7100
114,5420,-453
116,500,-7400
117,4617,605
118,7105,-828
120,-140,-7840
122,4922,-218
123,1672,-16953
124,-1705,4272
125,-3360,-7885
126,5472,2052
129,602,-5945
130,4817,6518
131,-4900,6927
132,-2527,-5767
133,-2925,-17792
135,4170,7413
136,-1000,-7600
137,3623,12790
138,2900,-17800
140,400,-5600
141,-5163,-5872
142,1123,7278
143,1820,10455
144,-3300,-5600
145,5703,2465
146,5545,2363
147,-3155,15908
148,800,-6600
149,3870,-2723
150,-2370,13233
152,2210,11350
153,-5460,15888
157,-52,16692
158,-1767,16838
159,415,7345
160,-2122,-17513
161,398,-8158
162,-2150,16550
163,-950,14712
165,-2035,5750
166,1518,14572
167,6000,1900
168,908,16733
169,-1288,4515
170,-3903,17447
171,-1740,15585
172,-2507,-13010
173,688,15820
174,2820,-17737
175,-1765,-14940
176,-1778,17792
177,2428,15397
179,4700,2900
180,4000,2400
181,-1825,3500
182,1840,-7500
185,-900,16000
187,1763,943
188,-1903,-16985
189,-2903,16793
190,-1393,-17170
191,-1002,-16108
192,2705,14220
195,-143,562
197,587,-16207
199,-6877,-9058
201,-4688,3772
202,1818,-6655
203,4258,162
204,1877,-11097
205,-793,-1437
206,4820,1630
207,-1970,6342
209,5070,485
211,4393,-5990
212,4283,2508
213,1808,-6303
214,4200,900
215,3500,3300
216,1255,-8172
217,-2628,-8007
219,22,657
221,5600,1000
222,6207,-693
223,5277,-147
224,6138,2482
225,4015,927
227,4600,200
230,5100,1000
232,203,4535
233,3615,-537
234,-2190,-15793
235,-5448,-3708
236,3978,2178
237,7400,-4278
238,-6060,-4555
239,4712,1928
240,-5843,-2633
241,-6208,-5867
242,6480,-1873
245,5313,-802
246,4190,1243
247,988,11423
248,4282,1258
249,1737,-6278
250,-1597,-572
251,4713,957
252,4700,-6000
253,0,-2900
254,5000,600
256,3275,-1695
257,3588,1442
259,7800,1600
260,4373,740
262,3882,7122
263,5228,547
265,5473,-668
266,6100,900
269,5228,1867
270,-940,-17120
272,3950,-800
273,-2050,-2932
274,-3713,-1230
275,4578,2470
276,-1588,5450
277,4677,-5620
278,4395,1245
279,5682,-418
280,3800,5800
281,4032,-343
282,-850,17920
283,3532,3357
284,5890,1533
285,1773,-6480
286,192,3260
287,4687,812
288,5000,3000
289,4075,-7397
291,3760,-9187
292,4140,6397
293,1580,10790
294,5228,-373
295,4190,1247
296,4400,2100
297,1928,16663
298,-1330,-17620
299,395,10223
301,142,17300
302,2482,-1385
303,-1622,15002
304,2603,5053
305,2412,8965
306,2740,9018
308,1000,-8400
309,2000,9637
312,1293,10513
315,760,8070
318,3600,10200
321,2228,11418
324,2250,7758
327,-730,10988
330,3200,5300
333,3392,4278
336,3132,3482
339,3640,13838
342,3118,3642
344,3978,12630
345,450,11460
348,2938,4738
354,3383,3583
363,4677,10217
369,2770,8533
370,2360,5855
372,3000,7000
375,1300,12200
376,2525,5113
378,2420,4383
379,-467,5547
381,137,10378
382,1175,4235
384,3538,3820
386,2372,12088
387,1260,9970
390,3918,3565
391,2400,5400
400,2800,200
401,-1250,1850
402,-2200,2400
404,-317,2978
406,538,1187
408,675,2033
409,1600,-2400
410,1580,1817
411,-1163,4330
412,-102,1537
414,-312,2303
416,987,225
420,-37,1173
422,1340,-1638
424,770,-157
428,758,-580
430,32,3815
432,-2922,2788
434,650,-950
436,2720,1660
438,-1900,4658
440,-1400,3400
442,1800,-258
444,2060,-1050
446,3200,-500
450,987,755
452,-1800,3100
453,-2112,5548
454,-175,2982
456,1520,-1463
458,850,-1325
460,-1248,17708
462,-2907,2263
464,-2200,1700
466,1447,2862
468,-2665,3148
470,-575,3392
474,3540,932
478,2628,2860
480,1200,-200
482,-1422,2673
483,840,128
489,-2200,17500
490,-88,16953
492,1565,4812
497,4518,1530
499,4600,1400
501,4432,1757
502,4160,2165
503,5000,1600
504,4900,2000
505,2070,11670
506,1508,11772
507,-1072,16580
508,-2337,-14948
509,-892,-14007
510,3128,3427
511,-880,12605
512,-1987,15832
513,-2470,-12480
514,4250,1928
515,-1105,-17125
516,1790,-6283
517,1217,-6900
518,1807,-6307
519,1757,-6310
520,1220,-6825
521,485,3160
522,4267,2117
"""

    static let entities: [DXCCNumericEntity] = raw.split(whereSeparator: \.isNewline).compactMap { row in
        let p = row.split(separator: ",")
        guard p.count == 3,
              let code = Int(p[0]), let lat100 = Int(p[1]), let lon100 = Int(p[2]) else { return nil }
        return DXCCNumericEntity(code: code, latitude: Double(lat100) / 100.0, longitude: Double(lon100) / 100.0)
    }

    static let byCode: [Int: DXCCNumericEntity] = Dictionary(uniqueKeysWithValues: entities.map { ($0.code, $0) })


    /// ARRL current-entity names keyed by numerical DXCC entity code. The
    /// roster mirrors CardSat `dxcc_lookup.h`; deleted entities are omitted.
    private static let rawNames = """
247|Spratly Is.
246|Sovereign Military Order of Malta
260|Monaco
4|Agalega & St. Brandon Is.
165|Mauritius
207|Rodrigues I.
49|Equatorial Guinea
195|Annobon I.
176|Fiji (Republic of)
489|Conway Reef
460|Rotuma I.
468|Kingdom of Eswatini
474|Tunisia
293|Viet Nam
107|Guinea
24|Bouvet
199|Peter 1 I.
18|Azerbaijan
75|Georgia
514|Montenegro
315|Sri Lanka
117|ITU HQ
289|United Nations HQ
511|Timor-Leste
336|Israel
436|Libya
215|Cyprus
470|Tanzania (United Republic of)
450|Nigeria
438|Madagascar
444|Mauritania
187|Niger
483|Togo
190|Samoa
286|Uganda
430|Kenya
456|Senegal
82|Jamaica
492|Yemen
432|Lesotho
440|Malawi
400|Algeria (People's Dem Rep of)
62|Barbados
159|Maldives
129|Guyana
497|Croatia
424|Ghana
257|Malta
482|Zambia
348|Kuwait
458|Sierra Leone
299|West Malaysia
46|East Malaysia
369|Nepal
414|Democratic Republic of the Congo
404|Burundi
381|Singapore (Republic of)
454|Rwanda
90|Trinidad & Tobago
402|Botswana (Republic of)
160|Tonga
370|Oman
306|Bhutan
391|United Arab Emirates
376|Qatar
304|Bahrain
372|Pakistan (Islamic Rep of)
318|China
506|Scarborough Reef
386|Taiwan
505|Pratas I.
157|Nauru
203|Andorra
422|Gambia (Republic of the)
60|Bahamas (Commonwealth of the)
181|Mozambique
112|Chile
47|Easter I.
125|Juan Fernandez Is.
217|San Felix & San Ambrosio
13|Antarctica
70|Cuba
446|Morocco (Kingdom of)
104|Bolivia
272|Portugal
256|Madeira Is.
149|Azores
144|Uruguay
211|Sable I.
252|St. Paul I.
401|Angola
409|Cabo Verde (Rep of)
411|Comoros
230|Germany (Federal Rep of)
375|Philippines
51|Eritrea
510|Palestine
191|North Cook Is.
234|South Cook Is.
188|Niue
501|Bosnia-Herzegovina
281|Spain
21|Balearic Is.
29|Canary Is.
32|Ceuta & Melilla
245|Ireland
14|Armenia
434|Liberia
330|Iran (Islamic Repub of)
179|Moldova (Republic of)
52|Estonia
53|Ethiopia
27|Belarus (Republic of)
135|Kyrgyz Republic
262|Tajikistan
280|Turkmenistan
227|France
79|Guadeloupe
169|Mayotte
516|Saint Barthelemy
162|New Caledonia
512|Chesterfield Is.
84|Martinique
508|Austral I.
36|Clipperton I.
175|French Polynesia
509|Marquesas Is.
277|St. Pierre & Miquelon
453|Reunion I.
99|Glorioso Is.
124|Juan de Nova, Europa
276|Tromelin I.
213|Saint Martin
41|Crozet I.
131|Kerguelen Is.
10|Amsterdam & St. Paul Is.
298|Wallis & Futuna Is.
63|French Guiana
223|United Kingdom of Great Britain
114|Isle of Man
265|Northern Ireland
122|Jersey
279|Scotland
106|Guernsey
294|Wales
185|Solomon Is.
507|Temotu Province
239|Hungary
287|Switzerland
251|Liechtenstein
120|Ecuador
71|Galapagos Is.
78|Haiti
72|Dominican Republic
116|Colombia
161|Malpelo I.
216|San Andres & Providencia
137|Korea (Republic of)
88|Panama
80|Honduras
387|Thailand
295|Vatican
378|Saudi Arabia
248|Italy
225|Sardinia
382|Djibouti
77|Grenada
109|Guinea-Bissau
97|St. Lucia
95|Dominica
98|St. Vincent
339|Japan
177|Minami Torishima
192|Ogasawara
363|Mongolia
259|Svalbard
118|Jan Mayen
342|Jordan
291|United States of America
105|Guantanamo Bay
166|Mariana Is.
20|Baker & Howland Is.
103|Guam
123|Johnston I.
174|Midway I.
197|Palmyra & Jarvis Is.
110|Hawaii
138|Kure I.
9|American Samoa
515|Swains I.
297|Wake I.
6|Alaska
182|Navassa I.
285|Virgin Is.
202|Puerto Rico
43|Desecheo I.
266|Norway
100|Argentina
254|Luxembourg
146|Lithuania
212|Bulgaria
136|Peru
354|Lebanon
206|Austria
224|Finland
5|Aland Is.
167|Market Reef
503|Czech Republic
504|Slovak Republic
209|Belgium
221|Denmark
237|Greenland
222|Faroe Is.
163|Papua New Guinea
91|Aruba
344|Democratic People's Rep. of Korea
263|Netherlands
517|Curacao
520|Bonaire
519|Saba & St. Eustatius
518|Sint Maarten
108|Brazil
56|Fernando de Noronha
253|St. Peter & St. Paul Rocks
273|Trindade & Martim Vaz Is.
140|Suriname
61|Franz Josef Land
302|Western Sahara
305|Bangladesh
499|Slovenia
379|Seychelles
219|Sao Tome & Principe
284|Sweden
269|Poland
466|Sudan
478|Egypt
236|Greece
180|Mount Athos
45|Dodecanese
40|Crete
282|Tuvalu
301|W. Kiribati (Gilbert Is. )
31|C. Kiribati (British Phoenix Is.)
48|E. Kiribati (Line Is.)
490|Banaba I. (Ocean I.)
232|Somalia
278|San Marino
22|Palau
390|Republic of Turkiye
242|Iceland
76|Guatemala
308|Costa Rica
37|Cocos I.
406|Cameroon
214|Corsica
408|Central Africa
412|Republic of the Congo
420|Gabon
410|Chad
428|Cote d'Ivoire
416|Benin
442|Mali
54|European Russia
126|Kaliningrad
15|Asiatic Russia
292|Uzbekistan
130|Kazakhstan
288|Ukraine
94|Antigua & Barbuda
66|Belize
249|St. Kitts & Nevis
464|Namibia
173|Micronesia
168|Marshall Is.
345|Brunei Darussalam
1|Canada
150|Australia
111|Heard I.
153|Macquarie I.
38|Cocos (Keeling) Is.
147|Lord Howe I.
171|Mellish Reef
189|Norfolk I.
303|Willis I.
35|Christmas I.
12|Anguilla
96|Montserrat
65|British Virgin Is.
89|Turks & Caicos Is.
172|Pitcairn I.
513|Ducie I.
141|Falkland Is.
235|South Georgia I.
238|South Orkney Is.
240|South Sandwich Is.
241|South Shetland Is.
64|Bermuda
33|Chagos Is.
321|Hong Kong
324|India
11|Andaman & Nicobar Is.
142|Lakshadweep Is.
50|Mexico
204|Revillagigedo
480|Burkina Faso
312|Cambodia
143|Lao People's Democratic Rep
152|Macao
309|Myanmar
3|Afghanistan
327|Indonesia
333|Iraq
158|Vanuatu
384|Syrian Arab Republic
145|Latvia
86|Nicaragua
275|Romania
74|El Salvador
296|Serbia
148|Venezuela
17|Aves I.
452|Zimbabwe
502|North Macedonia (Republic of)
522|Republic of Kosovo
521|South Sudan (Republic of)
7|Albania
233|Gibraltar
283|UK Sovereign Base Areas on Cyprus
250|St. Helena
205|Ascension I.
274|Tristan da Cunha & Gough I.
69|Cayman Is.
270|Tokelau Is.
170|New Zealand
34|Chatham Is.
133|Kermadec Is.
16|New Zealand Subantarctic Islands
132|Paraguay
462|South Africa
201|Prince Edward & Marion Is.
"""

    static let nameByCode: [Int: String] = Dictionary(uniqueKeysWithValues: rawNames.split(whereSeparator: \.isNewline).compactMap { row in
        guard let pipe = row.firstIndex(of: "|") else { return nil }
        guard let code = Int(row[..<pipe]) else { return nil }
        return (code, String(row[row.index(after: pipe)...]))
    })

    static let codeByName: [String: Int] = {
        var out: [String: Int] = [:]
        for (code, name) in nameByCode { out[name] = code }
        return out
    }()
}

// MARK: - Callsign → DXCC entity

/// Prefix-based callsign → DXCC entity lookup for the QSO log (ADIF `DXCC` /
/// `COUNTRY`). Longest-prefix match over the ITU/DXCC prefix blocks below, with
/// portable and compound calls resolved first (`K1ABC/VE3`, `VE3/K1ABC`, `/P`,
/// `/M`, `/QRP`, call-area digits like `/9`), `/MM` and `/AM` mapped to entity 0
/// ("not a DXCC entity"), plus code rules for Russia and Guantanamo Bay.
/// Prefixes shared by several entities (VK0, 3Y, E5, JD1, FT, …) deliberately
/// resolve to nothing rather than guess; the operator can fill those in.
enum DXCCLookup {
    struct Match: Equatable, Sendable {
        let code: Int          // ARRL DXCC entity code; 0 = not an entity (/MM, /AM)
        let name: String       // entity name, "" for code 0
    }

    /// Portable modifiers that never change the entity.
    private static let modifiers: Set<String> = ["P", "M", "QRP", "QRPP", "A", "B", "R", "LH", "PM"]
    /// Modifiers that put the station outside every DXCC entity.
    private static let noEntity: Set<String> = ["MM", "AM"]

    /// Entity for a callsign, or nil when the prefix is unknown or ambiguous.
    static func entity(for rawCall: String) -> Match? {
        let parts = callParts(rawCall)
        guard !parts.isEmpty else { return nil }
        if parts.dropFirst().contains(where: { noEntity.contains($0) }) { return Match(code: 0, name: "") }
        let core = parts.enumerated().filter { $0.offset == 0 || !modifiers.contains($0.element) }.map(\.element)
        guard let base = core.max(by: { $0.count < $1.count }) else { return nil }
        var target = base
        if core.count > 1, let short = core.min(by: { $0.count < $1.count }) {
            if short.count == 1, let digit = short.first, digit.isNumber {
                // A bare call-area digit (UA3ABC/9, K1ABC/6): swap it into the base call.
                if let i = base.firstIndex(where: \.isNumber) {
                    target = base.replacingCharacters(in: i...i, with: String(digit))
                }
            } else {
                // The shorter part is the location prefix (cty.dat convention); the first wins a tie.
                target = short
            }
        }
        guard let code = code(for: target), code >= 0 else { return nil }
        return Match(code: code, name: code == 0 ? "" : (DXCCNumericData.nameByCode[code] ?? ""))
    }

    /// The operator's own callsign inside a compound call (`VE3/K1ABC/P` → `K1ABC`),
    /// used for QRZ lookups.
    static func baseCall(_ rawCall: String) -> String {
        callParts(rawCall).max(by: { $0.count < $1.count }) ?? ""
    }

    private static func callParts(_ rawCall: String) -> [String] {
        rawCall.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/").map(String.init).filter { !$0.isEmpty }
    }

    private static func code(for call: String) -> Int? {
        let chars = Array(call)
        guard let first = chars.first else { return nil }
        // Russia: R* and UA–UI. Call area 2 is Kaliningrad, 8/9/0 are Asiatic Russia.
        if first == "R" || (first == "U" && chars.count > 1 && "ABCDEFGHI".contains(chars[1])) {
            switch chars.first(where: \.isNumber) {
            case "2": return 126
            case "8", "9", "0": return 15
            default: return 54
            }
        }
        // Guantanamo Bay is KG4 with a two-letter suffix (KG4AB); KG4ABC is the US.
        if call.hasPrefix("KG4") && call.count == 5 { return 105 }
        for len in stride(from: min(maxPrefixLength, call.count), through: 1, by: -1) {
            if let code = table[String(call.prefix(len))] { return code }
        }
        return nil
    }

    /// `code|prefix prefix …`; `AA-AK` expands the last character's range.
    /// Code -1 marks prefixes shared by several entities (no automatic entity).
    private static let rawPrefixes = """
-1|VK0 3Y E5 JD1 FT TO TX 4U KC4 CE9
1|VA-VG VO VY CF-CK CY CZ XJ-XO
211|CY0
252|CY9
291|K W N AA-AK
6|AL KL NL WL
110|KH6 KH7 AH6 AH7 NH6 NH7 WH6 WH7
166|KH0 AH0 NH0 WH0
20|KH1 AH1 NH1 WH1
103|KH2 AH2 NH2 WH2
123|KH3 AH3 NH3 WH3
174|KH4 AH4 NH4 WH4
197|KH5 AH5 NH5 WH5
9|KH8 AH8 NH8 WH8
297|KH9 AH9 NH9 WH9
182|KP1 NP1 WP1
285|KP2 NP2 WP2
202|KP3 KP4 NP3 NP4 WP3 WP4
43|KP5 NP5 WP5
50|XA-XI 4A-4C 6D-6J
204|XF4
223|G M 2
114|GD MD 2D GT MT
265|GI MI 2I GN MN
122|GJ MJ 2J GH MH
279|GM MM 2M GS MS
106|GU MU 2U GP MP
294|GW MW 2W GC MC
227|F TM TH HW-HY
79|FG
169|FH
516|FJ
162|FK
84|FM
175|FO
277|FP
453|FR
213|FS
298|FW
63|FY
41|FT5W FT8W
131|FT5X FT8X
10|FT5Z FT8Z
214|TK
230|DA-DR Y2-Y9
281|EA-EH AM-AO
21|EA6 EB6 EC6 ED6 EE6 EF6 EG6 EH6
29|EA8 EB8 EC8 ED8 EE8 EF8 EG8 EH8
32|EA9 EB9 EC9 ED9 EE9 EF9 EG9 EH9
248|I
225|IS0 IM0
272|CQ CR CS CT
256|CT3 CQ3 CR3 CS3
149|CU CT8 CQ8 CR8 CS8
144|CV-CX
112|CA-CE XQ-XR 3G
47|CE0Y
217|CE0X
125|CE0Z
100|AY-AZ L2-L9 LO-LW
108|PP-PY ZV-ZZ
56|PY0F
253|PY0S
273|PY0T
136|OA-OC
120|HC HD
71|HC8 HD8
116|HJ HK 5J 5K
216|HK0
148|YV-YY 4M
17|YV0
104|CP
132|ZP
140|PZ
129|8R
70|CL CM CO T4
78|HH 4V
72|HI
82|6Y
60|C6
62|8P
90|9Y 9Z
77|J3
97|J6
95|J7
98|J8
94|V2
249|V4
66|V3
76|TG TD
80|HQ HR
74|YS HU
86|YN H6 H7 HT
308|TI TE
37|TI9
88|HO HP 3E 3F H3 H8 H9
91|P4
517|PJ2
520|PJ4
519|PJ5 PJ6
518|PJ7
12|VP2E
96|VP2M
65|VP2V
89|VP5
69|ZF
64|VP9
141|VP8
172|VP6
237|OX XP
222|OY
221|OU OV OW OZ 5P 5Q
266|LA-LN
259|JW
118|JX
284|SA-SM 7S 8S
224|OF-OI
5|OH0
167|OJ0
242|TF
245|EI EJ
209|ON-OT
263|PA-PI
254|LX
287|HB HE
251|HB0
206|OE
239|HA HG
503|OK OL
504|OM
269|SN-SR HF 3Z
146|LY
145|YL
52|ES
27|EU-EW
288|UR-UZ EM-EO
179|ER
275|YO-YR
212|LZ
236|SV-SZ J4
45|SV5 SX5 J45
40|SV9 SW9 SX9 J49
215|5B C4 H2 P3
283|ZC4
390|TA-TC YM
257|9H
233|ZB2
203|C3
260|3A
278|T7
295|HV
246|1A
497|9A
499|S5
501|E7 T9
296|YT YU
514|4O
502|Z3
7|ZA
522|Z6
75|4L
14|EK
18|4J 4K
130|UN-UQ
292|UJ-UM
135|EX
262|EY
280|EZ
336|4X 4Z
510|E4
342|JY
354|OD
384|YK 6C
333|YI HN
330|EP EQ 9B-9D
348|9K
378|HZ 7Z 8Z
304|A9
376|A7
391|A6
370|A4
492|7O
3|YA T6
372|AP-AS 6P-6S
324|VU AT-AW 8T-8Y
11|VU4
142|VU7
315|4P-4S
159|8Q
369|9N
306|A5
305|S2 S3
309|XY XZ
387|HS E2
143|XW
312|XU
293|3W XV
318|B 3H-3U XS
386|BM BN BO BP BQ BU BV BW BX
505|BV9P
506|BS7
321|VR
152|XX9
363|JT JU JV
344|HM P5
137|HL 6K-6N DS DT D7-D9
339|JA-JS 7J-7N 8J-8N
375|DU-DZ 4D-4I
327|YB-YH 7A-7I 8A-8I PK-PO
299|9M 9W
46|9M6 9M8 9W6 9W8
381|9V S6
345|V8
511|4W
163|P2
150|VH-VN AX
38|VK9C
147|VK9L
171|VK9M
189|VK9N
303|VK9W
35|VK9X
170|ZL ZM
34|ZL7
133|ZL8
16|ZL9
270|ZK3
188|E6
190|5W
160|A3
176|3D2
468|3DA
158|YJ
185|H4
507|H40
301|T30
31|T31
48|T32
490|T33
282|T2
157|C2
168|V7
173|V6
22|T8
478|SU 6A 6B
436|5A
474|3V TS
400|7R 7T-7Y
446|CN 5C-5G
302|S0
444|5T
456|6V 6W
422|C5
109|J5
107|3X
458|9L
434|EL 5L 5M 6Z A8 D5
428|TU
424|9G
483|5V
416|TY
450|5N 5O
187|5U
442|TZ
480|XT
410|TT
406|TJ
408|TL
420|TR
412|TN
414|9O-9T
49|3C
195|3C0
219|S9
401|D2 D3
464|V5
402|A2 8O
462|ZR-ZU
201|ZS8
432|7P
181|C8 C9
452|Z2
482|9I 9J
440|7Q
470|5H 5I
430|5Y 5Z
286|5X
454|9X
404|9U
53|ET 9E 9F
51|E3
382|J2
232|6O T5
466|ST 6T 6U
521|Z8
438|5R 5S 6X
165|3B8
4|3B6 3B7
207|3B9
411|D6
379|S7
409|D4
250|ZD7
205|ZD8
274|ZD9
33|VQ9
117|4U1I
289|4U1U
"""

    private static let table: [String: Int] = {
        var out: [String: Int] = [:]
        for row in rawPrefixes.split(whereSeparator: \.isNewline) {
            guard let pipe = row.firstIndex(of: "|"), let code = Int(row[..<pipe]) else { continue }
            for token in row[row.index(after: pipe)...].split(separator: " ") {
                let ends = token.split(separator: "-")
                if ends.count == 2, ends[0].count == ends[1].count, ends[0].dropLast() == ends[1].dropLast(),
                   let a = ends[0].unicodeScalars.last, let b = ends[1].unicodeScalars.last, a.value <= b.value {
                    let stem = String(ends[0].dropLast())
                    for v in a.value...b.value { if let s = Unicode.Scalar(v) { out[stem + String(Character(s))] = code } }
                } else {
                    out[String(token)] = code
                }
            }
        }
        return out
    }()

    private static let maxPrefixLength = table.keys.map(\.count).max() ?? 1
}
