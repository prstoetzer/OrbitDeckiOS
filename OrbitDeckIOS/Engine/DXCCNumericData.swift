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

// MARK: - LoTW station subdivisions

/// LoTW's DXCC entity list and administrative-subdivision enumerations for the
/// station-location picker, ported from CardSat `lotw_subdiv.h` (itself generated
/// from TQSL 2.8.6 config.xml). The dependsOn chain is DXCC → primary (US state,
/// Canadian province, Russian oblast, Japanese prefecture, Chinese province,
/// Australian state, Finnish kunta) → secondary (US county, Japanese city/gun/ku).
/// Entities with a primary subdivision come first in `entities`.
enum LoTWSubdivisions {
    struct Entity: Identifiable, Hashable, Sendable {
        let id: Int              // DXCC entity code
        let name: String
        let primaryField: String     // LoTW field name, "" = none
        let secondaryField: String
    }
    struct Option: Identifiable, Hashable, Sendable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let entities: [Entity] = rawEntities.split(whereSeparator: \.isNewline).compactMap { row in
        let p = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 4, let id = Int(p[0]) else { return nil }
        return Entity(id: id, name: p[1], primaryField: p[2], secondaryField: p[3])
    }

    static func entity(_ code: Int?) -> Entity? {
        guard let code else { return nil }
        return entities.first { $0.id == code }
    }

    /// Choices for a primary field. US_STATE is narrowed per entity the way TQSL does:
    /// Alaska and Hawaii are their own DXCC entities with a single state each.
    static func primaryOptions(for entity: Entity) -> [Option] {
        let all = tables[entity.primaryField] ?? []
        guard entity.primaryField == "US_STATE" else { return all }
        switch entity.id {
        case 6: return all.filter { $0.code == "AK" }
        case 110: return all.filter { $0.code == "HI" }
        default: return all.filter { $0.code != "AK" && $0.code != "HI" }.sorted { $0.name < $1.name }
        }
    }

    /// Choices for a secondary field, gated by the chosen primary code.
    static func secondaryOptions(for entity: Entity, primary: String) -> [Option] {
        guard !entity.secondaryField.isEmpty, !primary.isEmpty else { return [] }
        return tables["\(entity.secondaryField)/\(primary.uppercased())"] ?? []
    }

    /// US states plus DC (WAS counts 50 + DC), alphabetical by name.
    static var usStates: [Option] { (tables["US_STATE"] ?? []).sorted { $0.name < $1.name } }

    /// Human label for a LoTW field name.
    static func label(_ field: String) -> String {
        switch field {
        case "US_STATE", "AU_STATE": "State"
        case "CA_PROVINCE", "CN_PROVINCE": "Province"
        case "RU_OBLAST": "Oblast"
        case "JA_PREFECTURE": "Prefecture"
        case "FI_KUNTA": "Kunta"
        case "US_COUNTY": "County"
        case "JA_CITY_GUN_KU": "City/gun/ku"
        default: "Subdivision"
        }
    }

    /// "@FIELD" or "@FIELD/PARENT" section headers, then "code|name" rows.
    private static let tables: [String: [Option]] = {
        var out: [String: [Option]] = [:]
        var key = ""
        for row in rawTables.split(whereSeparator: \.isNewline) {
            if row.hasPrefix("@") { key = String(row.dropFirst()); continue }
            guard let pipe = row.firstIndex(of: "|") else { continue }
            out[key, default: []].append(Option(code: String(row[..<pipe]), name: String(row[row.index(after: pipe)...])))
        }
        return out
    }()

    private static let rawEntities = """
5|ALAND ISLANDS|FI_KUNTA|
6|ALASKA|US_STATE|US_COUNTY
15|ASIATIC RUSSIA|RU_OBLAST|
150|AUSTRALIA|AU_STATE|
1|CANADA|CA_PROVINCE|
318|CHINA|CN_PROVINCE|
54|EUROPEAN RUSSIA|RU_OBLAST|
224|FINLAND|FI_KUNTA|
61|FRANZ JOSEF LAND|RU_OBLAST|
110|HAWAII|US_STATE|US_COUNTY
339|JAPAN|JA_PREFECTURE|JA_CITY_GUN_KU
126|KALININGRAD|RU_OBLAST|
167|MARKET REEF|FI_KUNTA|
291|UNITED STATES OF AMERICA|US_STATE|US_COUNTY
3|AFGHANISTAN||
4|AGALEGA & SAINT BRANDON ISLANDS||
7|ALBANIA||
400|ALGERIA||
9|AMERICAN SAMOA||
10|AMSTERDAM & SAINT PAUL ISLANDS||
11|ANDAMAN & NICOBAR ISLANDS||
203|ANDORRA||
401|ANGOLA||
12|ANGUILLA||
195|ANNOBON||
13|ANTARCTICA||
94|ANTIGUA & BARBUDA||
100|ARGENTINA||
14|ARMENIA||
91|ARUBA||
205|ASCENSION ISLAND||
508|AUSTRAL ISLANDS||
206|AUSTRIA||
17|AVES ISLAND||
18|AZERBAIJAN||
149|AZORES||
60|BAHAMAS||
304|BAHRAIN||
20|BAKER & HOWLAND ISLANDS||
21|BALEARIC ISLANDS||
490|BANABA ISLAND||
305|BANGLADESH||
62|BARBADOS||
27|BELARUS||
209|BELGIUM||
66|BELIZE||
416|BENIN||
64|BERMUDA||
306|BHUTAN||
104|BOLIVIA||
520|BONAIRE||
501|BOSNIA-HERZEGOVINA||
402|BOTSWANA||
24|BOUVET ISLAND||
108|BRAZIL||
65|BRITISH VIRGIN ISLANDS||
345|BRUNEI||
212|BULGARIA||
480|BURKINA FASO||
404|BURUNDI||
312|CAMBODIA||
406|CAMEROON||
29|CANARY ISLANDS||
409|CAPE VERDE||
69|CAYMAN ISLANDS||
408|CENTRAL AFRICAN REPUBLIC||
31|CENTRAL KIRIBATI||
32|CEUTA & MELILLA||
410|CHAD||
33|CHAGOS ISLANDS||
34|CHATHAM ISLAND||
512|CHESTERFIELD ISLANDS||
112|CHILE||
35|CHRISTMAS ISLAND||
36|CLIPPERTON ISLAND||
38|COCOS (KEELING) ISLANDS||
37|COCOS ISLAND||
116|COLOMBIA||
411|COMOROS||
489|CONWAY REEF||
214|CORSICA||
308|COSTA RICA||
428|COTE D'IVOIRE||
40|CRETE||
497|CROATIA||
41|CROZET ISLAND||
70|CUBA||
517|CURACAO||
215|CYPRUS||
503|CZECH REPUBLIC||
414|DEMOCRATIC REPUBLIC OF THE CONGO||
221|DENMARK||
43|DESECHEO ISLAND||
382|DJIBOUTI||
45|DODECANESE||
95|DOMINICA||
72|DOMINICAN REPUBLIC||
344|DPRK (NORTH KOREA)||
513|DUCIE ISLAND||
46|EAST MALAYSIA||
47|EASTER ISLAND||
48|EASTERN KIRIBATI||
120|ECUADOR||
478|EGYPT||
74|EL SALVADOR||
223|ENGLAND||
49|EQUATORIAL GUINEA||
51|ERITREA||
52|ESTONIA||
53|ETHIOPIA||
141|FALKLAND ISLANDS||
222|FAROE ISLANDS||
230|FEDERAL REPUBLIC OF GERMANY||
56|FERNANDO DE NORONHA||
176|FIJI ISLANDS||
227|FRANCE||
63|FRENCH GUIANA||
175|FRENCH POLYNESIA||
420|GABON||
71|GALAPAGOS ISLANDS||
75|GEORGIA||
424|GHANA||
233|GIBRALTAR||
99|GLORIOSO ISLAND||
236|GREECE||
237|GREENLAND||
77|GRENADA||
79|GUADELOUPE||
103|GUAM||
105|GUANTANAMO BAY||
76|GUATEMALA||
106|GUERNSEY||
107|GUINEA||
109|GUINEA-BISSAU||
129|GUYANA||
78|HAITI||
111|HEARD ISLAND||
80|HONDURAS||
321|HONG KONG||
239|HUNGARY||
242|ICELAND||
324|INDIA||
327|INDONESIA||
330|IRAN||
333|IRAQ||
245|IRELAND||
114|ISLE OF MAN||
336|ISRAEL||
248|ITALY||
117|ITU HQ||
82|JAMAICA||
118|JAN MAYEN||
122|JERSEY||
123|JOHNSTON ISLAND||
342|JORDAN||
124|JUAN DE NOVA, EUROPA||
125|JUAN FERNANDEZ ISLAND||
130|KAZAKHSTAN||
430|KENYA||
131|KERGUELEN ISLAND||
133|KERMADEC ISLAND||
468|KINGDOM OF ESWATINI||
138|KURE ISLAND||
348|KUWAIT||
135|KYRGYZSTAN||
142|LAKSHADWEEP ISLANDS||
143|LAOS||
145|LATVIA||
354|LEBANON||
432|LESOTHO||
434|LIBERIA||
436|LIBYA||
251|LIECHTENSTEIN||
146|LITHUANIA||
147|LORD HOWE ISLAND||
254|LUXEMBOURG||
152|MACAO||
153|MACQUARIE ISLAND||
438|MADAGASCAR||
256|MADEIRA ISLANDS||
440|MALAWI||
159|MALDIVES||
442|MALI||
161|MALPELO ISLAND||
257|MALTA||
166|MARIANA ISLANDS||
509|MARQUESAS ISLANDS||
168|MARSHALL ISLANDS||
84|MARTINIQUE||
444|MAURITANIA||
165|MAURITIUS ISLAND||
169|MAYOTTE ISLAND||
171|MELLISH REEF||
50|MEXICO||
173|MICRONESIA||
174|MIDWAY ISLAND||
177|MINAMI TORISHIMA||
179|MOLDOVA||
260|MONACO||
363|MONGOLIA||
514|MONTENEGRO||
96|MONTSERRAT||
446|MOROCCO||
180|MOUNT ATHOS||
181|MOZAMBIQUE||
309|MYANMAR||
464|NAMIBIA||
157|NAURU||
182|NAVASSA ISLAND||
369|NEPAL||
263|NETHERLANDS||
162|NEW CALEDONIA||
170|NEW ZEALAND||
16|NEW ZEALAND SUBANTARCTIC ISLANDS||
86|NICARAGUA||
187|NIGER||
450|NIGERIA||
188|NIUE||
189|NORFOLK ISLAND||
191|NORTH COOK ISLANDS||
502|NORTH MACEDONIA||
265|NORTHERN IRELAND||
266|NORWAY||
192|OGASAWARA||
370|OMAN||
372|PAKISTAN||
22|PALAU||
510|PALESTINE||
197|PALMYRA & JARVIS ISLANDS||
88|PANAMA||
163|PAPUA NEW GUINEA||
132|PARAGUAY||
136|PERU||
199|PETER 1 ISLAND||
375|PHILIPPINES||
172|PITCAIRN ISLAND||
269|POLAND||
272|PORTUGAL||
505|PRATAS ISLAND||
201|PRINCE EDWARD & MARION ISLANDS||
202|PUERTO RICO||
376|QATAR||
137|REPUBLIC OF KOREA||
522|REPUBLIC OF KOSOVO||
462|REPUBLIC OF SOUTH AFRICA||
521|REPUBLIC OF SOUTH SUDAN||
412|REPUBLIC OF THE CONGO||
453|REUNION ISLAND||
204|REVILLAGIGEDO||
207|RODRIGUEZ ISLAND||
275|ROMANIA||
460|ROTUMA||
454|RWANDA||
519|SABA & SAINT EUSTATIUS||
211|SABLE ISLAND||
516|SAINT BARTHELEMY||
250|SAINT HELENA||
249|SAINT KITTS & NEVIS||
97|SAINT LUCIA||
213|SAINT MARTIN||
252|SAINT PAUL ISLAND||
253|SAINT PETER AND PAUL ROCKS||
277|SAINT PIERRE & MIQUELON||
98|SAINT VINCENT||
190|SAMOA||
216|SAN ANDRES ISLAND||
217|SAN FELIX ISLAND||
278|SAN MARINO||
219|SAO TOME & PRINCIPE||
225|SARDINIA||
378|SAUDI ARABIA||
506|SCARBOROUGH REEF||
279|SCOTLAND||
456|SENEGAL||
296|SERBIA||
379|SEYCHELLES ISLANDS||
458|SIERRA LEONE||
381|SINGAPORE||
518|SINT MAARTEN||
504|SLOVAK REPUBLIC||
499|SLOVENIA||
185|SOLOMON ISLANDS||
232|SOMALIA||
234|SOUTH COOK ISLANDS||
235|SOUTH GEORGIA ISLAND||
238|SOUTH ORKNEY ISLANDS||
240|SOUTH SANDWICH ISLANDS||
241|SOUTH SHETLAND ISLANDS||
246|SOVEREIGN MILITARY ORDER OF MALTA||
281|SPAIN||
247|SPRATLY ISLANDS||
315|SRI LANKA||
466|SUDAN||
140|SURINAME||
259|SVALBARD||
515|SWAINS ISLAND||
284|SWEDEN||
287|SWITZERLAND||
384|SYRIA||
386|TAIWAN||
262|TAJIKISTAN||
470|TANZANIA||
507|TEMOTU PROVINCE||
387|THAILAND||
422|THE GAMBIA||
511|TIMOR - LESTE||
483|TOGO||
270|TOKELAU ISLANDS||
160|TONGA||
273|TRINDADE & MARTIM VAZ ISLANDS||
90|TRINIDAD & TOBAGO||
274|TRISTAN DA CUNHA & GOUGH ISLANDS||
276|TROMELIN ISLAND||
474|TUNISIA||
390|TURKEY||
280|TURKMENISTAN||
89|TURKS & CAICOS ISLANDS||
282|TUVALU||
283|U K BASES ON CYPRUS||
286|UGANDA||
288|UKRAINE||
391|UNITED ARAB EMIRATES||
289|UNITED NATIONS HQ||
144|URUGUAY||
285|US VIRGIN ISLANDS||
292|UZBEKISTAN||
158|VANUATU||
295|VATICAN CITY||
148|VENEZUELA||
293|VIET NAM||
297|WAKE ISLAND||
294|WALES||
298|WALLIS & FUTUNA ISLANDS||
299|WEST MALAYSIA||
301|WESTERN KIRIBATI||
302|WESTERN SAHARA||
303|WILLIS ISLAND||
492|YEMEN||
482|ZAMBIA||
452|ZIMBABWE||
"""

    private static let rawTables = """
@US_STATE
HI|Hawaii
AL|Alabama
AZ|Arizona
AR|Arkansas
CA|California
CO|Colorado
CT|Connecticut
DE|Delaware
DC|District of Columbia
FL|Florida
GA|Georgia
ID|Idaho
IL|Illinois
IN|Indiana
IA|Iowa
KS|Kansas
KY|Kentucky
LA|Louisiana
ME|Maine
MD|Maryland
MA|Massachusetts
MI|Michigan
MN|Minnesota
MS|Mississippi
MO|Missouri
MT|Montana
NE|Nebraska
NV|Nevada
NH|New Hampshire
NJ|New Jersey
NM|New Mexico
NY|New York
NC|North Carolina
ND|North Dakota
OH|Ohio
OK|Oklahoma
OR|Oregon
PA|Pennsylvania
RI|Rhode Island
SC|South Carolina
SD|South Dakota
TN|Tennessee
TX|Texas
UT|Utah
VT|Vermont
VA|Virginia
WA|Washington
WV|West Virginia
WI|Wisconsin
WY|Wyoming
AK|Alaska
@CA_PROVINCE
AB|Alberta
BC|British Columbia
MB|Manitoba
NB|New Brunswick
NF|Newfoundland and Labrador
NT|Northwest Territories
NS|Nova Scotia
NU|Nunavut
ON|Ontario
PE|Prince Edward Island
PQ|Quebec
SK|Saskatchewan
YT|Yukon Territory
@RU_OBLAST
KA|Kaliningradskaya oblast' (Kaliningrad Oblast)
AB|Aginsky Buryatsky avtonomny okrug (Agin-Buryat Autonomous Okrug) [DELETED]
AL|Altayskiy kray (Altai Krai)
AM|Amurskaya oblast' (Amur Oblast)
BA|Respublika Bashkortostan (Republic of Bashkortostan) (Bashkortostan Republic)
BU|Respublika Buryatiya (Republic of Buryatia)
CB|Chelyabinskaya oblast' (Chelyabinsk Oblast)
CK|Chukotsky avtonomny okrug (Chukotka Autonomous Okrug)
CT|Zabaykalsky kray (Zabaykalsky Krai)
EA|Yevreyskaya avtonomnaya oblast' (Jewish Autonomous Oblast)
EW|Evenkiysky avtonomny okrug (Evenk Autonomous Okrug) [DELETED]
GA|Respublika Altay (Altai Republic) (Altay Republits)
HA|Respublika Khakasiya (Khakasiya Republits) (Republic of Khakassia)
HK|Khabarovskiy kray (Khabarovsk Krai)
HM|Khanty-Mansiyskiy avtonomnyy okrug (Khanty-Mansi Autonomous Okrug)
IR|Irkutskaya oblast' (Irkutsk Oblast)
JN|Yamalo-Nenetsky avtonomny okrug (Yamalo-Nenets Autonomous Okrug)
KE|Kemerovskaya oblast' (Kemerovo Oblast)
KJ|Koryaksky avtonomny okrug (Koryak Autonomous Okrug) [DELETED]
KK|Krasnoyarskiy kray (Krasnoyarsk Krai)
KN|Kurganskaya oblast' (Kurgan Oblast)
KT|Kamchatskiy kray (Kamchatka Krai)
MG|Magadanskaya oblast' (Magadan Oblast)
NS|Novosibirskaya oblast' (Novosibirsk Oblast)
OB|Orenburgskaya oblast' (Orenburg Oblast)
OM|Omskaya oblast' (Omsk Oblast)
PK|Primorskiy kray (Primorsky Krai)
SL|Sakhalinskaya oblast' (Sakhalin Oblast)
SV|Sverdlovskaya oblast' (Sverdlovsk Oblast)
TM|Taymyrsky Dolgano-Nenetsky avtonomny okru (Taymyr Autonomous Okrug) (Taymyria) [DELETED]
TN|Tyumenskaya oblast' (Tyumen Oblast)
TO|Tomskaya oblast' (Tomsk Oblast)
TU|Respublika Tyva (Tyva Republic) (Tyva Republits)
UO|Ust-Ordynsky avtonomny okrug (Ust-Orda Buryat Autonomous Okrug) [DELETED]
YA|Respublika Sakha (Yakutiya)
LO|Leningradskaya oblast' (Leningrad Oblast)
AD|Adygea (Adygea Republic}
AO|Astrakhanskaya oblast' (Astrakhan Oblast)
AR|Arkhangelskaya oblast' (Arkhangelsk Oblast)
BO|Belgorodskaya oblast' (Belgorod Oblast)
BR|Bryanskaya oblast' (Bryansk Oblast)
CC|Chechenskaya Respublika (Chechnya)
CU|Chuvashiya (Chuvashia Republic) (Chuvash Republic)
DA|Dagestan Republits (Dagestan Republic)
IN|Respublika Ingushetiya (Republic of Ingushetia)
IV|Ivanovskaya oblast' (Ivanovo Oblast)
JA|Yaroslavskaya oblast' (Yaroslavl Oblast)
KB|Kabardino-Balkarskaya Respublika (Kabardino-Balkaria)
KC|Karachay-Cherkessia (Karachay-Cherkess Republic)
KG|Kaluzhskaya oblast' (Kaluga Oblast)
KI|Kirovskaya oblast' (Kirov Oblast)
KL|Respublika Karelia (Karelia Republic)
KM|Respublika Kalmykiya (Kalmykia Republic) (Kalmykia)
KO|Respúblika Komi (Komi Republic)
KP|Komi-Permyatsky avtonomny okrug (Komi-Permyak Autonomous Okrug) [DELETED]
KR|Krasnodarskiy kray (Krasnodar Krai)
KS|Kostromskaya oblast' (Kostroma Oblast)
KU|Kurskaya oblast' (Kursk Oblast)
LO|Leningradskaya oblast' (Leningrad Oblast)
LP|Lipetsk Oblast (Lipetskaya oblast')
MA|Moskva (Moscow)
MD|Respublika Mordoviya (Republic of Mordovia)
MO|Moskovskaya oblast' (Moscow Oblast)
MR|Respublika Mariy El (Mari El Republic)
MU|Murmanskaya oblast' (Murmansk Oblast)
NN|Nizhegorodskaya oblast' (Nizhny Novgorod Oblast)
NO|Nenetsky avtonomny okrug (Nenets Autonomous Okrug)
NV|Novgorodskaya oblast' (Novgorod Oblast)
OR|Orlovskaya oblast' (Oryol Oblast)
PE|Penzenskaya oblast' (Penza Oblast)
PM|Permskiy kray	 (Perm Krai)
PS|Pskovskaya oblast' (Pskov Oblast)
RA|Ryazanskaya oblast' (Ryazan Oblast)
RO|Rostovskaya oblast' (Rostov Oblast)
SA|Saratovskaya oblast' (Saratov Oblast)
SM|Smolenskaya oblast' (Smolensk Oblast)
SO|Severnaya Osetiya (North Ossetia-Alania) (North Ossetia-Alania Republic)
SP|Sankt-Peterburg (Saint Petersburg)
SR|Samarskaya oblast' (Samara Oblast)
ST|Stavropolskiy kray (Stavropol Krai)
TA|Respublika Tatarstan (Tatarstan) (Tatarstan Republic)
TB|Tambovskaya oblast' (Tambov Oblast)
TL|Tulskaya oblast' (Tula Oblast)
TV|Tverskaya oblast'  (Tver Oblast)
UD|Udmurtskaja Respublika (Udmurt Republic)
UL|Ulyanovskaya oblast' (Ulyanovsk Oblast)
VG|Volgogradskaya oblast' (Volgograd Oblast)
VL|Vladimirskaya oblast' (Vladimir Oblast)
VO|Vologodskaya oblast' (Vologda Oblast)
VR|Voronezhskaya oblast' (Voronezh Oblast)
AR|Arkhangelskaya oblast' (Arkhangelsk Oblast)
@JA_PREFECTURE
01|Hokkaido-do
02|Aomori-ken
03|Iwate-ken
04|Akita-ken
05|Yamagata-ken
06|Miyagi-ken
07|Fukushima-ken
08|Niigata-ken
09|Nagano-ken
10|Tokyo-to
11|Kanagawa-ken
12|Chiba-ken
13|Saitama-ken
14|Ibaraki-ken
15|Tochigi-ken
16|Gunma-ken
17|Yamanashi-ken
18|Shizuoka-ken
19|Gifu-ken
20|Aichi-ken
21|Mie-ken
22|Kyoto-ken
23|Shiga-ken
24|Nara-ken
25|Osaka-fu
26|Wakayama-ken
27|Hyogo-ken
28|Toyama-ken
29|Fukui-ken
30|Ishikawa-ken
31|Okayama-ken
32|Shimane-ken
33|Yamaguchi-ken
34|Tottori-ken
35|Hiroshima-ken
36|Kagawa-ken
37|Tokushima-ken
38|Ehime-ken
39|Kochi-ken
40|Fukuoka-ken
41|Saga-ken
42|Nagasaki-ken
43|Kumamoto-ken
44|Oita-ken
45|Miyazaki-ken
46|Kagoshima-ken
47|Okinawa-ken
@CN_PROVINCE
AH|Anhui
BJ|Beijing
CQ|Chongqing
FJ|Fujian
GD|Guangdong
GS|Gansu
GX|Guangxi
GZ|Guizhou
HA|Henan
HB|Hubei
HE|Hebei
HI|Hainan
HL|Heilongjiang
HN|Hunan
JL|Jilin
JS|Jiangsu
JX|Jiangxi
LN|Liaoning
NM|Nei Mongol
NX|Ningxia
QH|Qinghai
SC|Sichuan
SD|Shandong
SH|Shanghai
SN|Shaanxi
SX|Shanxi
TJ|Tianjin
XJ|Xinjiang
XZ|Xizang
YN|Yunnan
ZJ|Zhejiang
@AU_STATE
ACT|Australian Capital Territory
NSW|New South Wales
VIC|Victoria
QLD|Queensland
SA|South Australia
WA|Western Australia
TAS|Tasmania
NT|Northern Territory
@FI_KUNTA
6|Hammarland
100|Somero
101|Ahlainen
102|Alastaro
103|Askainen (Villnäs)
104|Aura
105|Dragsfjärd
106|Eura
107|Eurajoki
108|Halikko
109|Harjavalta
110|Honkajoki
111|Houtskari (Houtskär)
112|Huittinen
113|Hämeenkyrö
114|Ikaalinen
115|Iniö
116|Jämijärvi
117|Kaarina (St. Karins)
118|Kalanti
119|Kankaanpää
120|Karinainen
121|Karjala
122|Karvia
123|Äetsä (Keikyä)
124|Kemiönsaari (Kemiö)
125|Kihniö
126|Kiikala
127|Kiikka
128|Kiikoinen
129|Kisko
130|Kiukainen
131|Kodisjoki
132|Kokemäki (Kumo)
133|Korppoo (Korpo)
134|Koski tl
135|Kullaa
136|Kustavi (Gustavs)
137|Kuusjoki
138|Köyliö (Kjulo)
139|Laitila
140|Lappi
141|Lavia
142|Lemu
143|Lieto
144|Loimaa
145|Loimaan kunta (Loimaan mlk)
146|Lokalahti
147|Luvia
148|Marttila
149|Masku
150|Mellilä
151|Merikarvia
152|Merimasku
153|Metsämaa
154|Mietoinen
155|Mouhijärvi
156|Muurla
157|Mynämäki
158|Naantali (Nådendal)
159|Nakkila
160|Nauvo (Nagu)
161|Noormarkku (Norrmark)
162|Nousiainen
163|Oripää
164|Paimio (Permar)
165|Parainen (Pargas)
166|Parkano
167|Perniö (Bjärnå)
168|Pertteli
169|Piikkiö (Pikis)
170|Pomarkku (Påmark)
171|Pori (Björneborg)
172|Punkalaidun
173|Pyhäranta
174|Pöytyä
175|Raisio (Reso)
176|Rauma (Raumo)
177|Rauman mlk (Raumo lk)
178|Rusko
179|Rymättylä (Rimito)
180|Salo
181|Sauvo
182|Siikainen
183|Suodenniemi
184|Suomusjärvi
185|Säkylä
186|Särkisalo
187|Taivassalo
188|Tarvasjoki
189|Turku (Åbo)
190|Ulvila
191|Uusikaupunki (Nystad)
192|Vahto
193|Sastamala (Vammala)
194|Vampula
195|Vehmaa
196|Velkua
197|Viljakkala
198|Västanfjärd
199|Yläne
201|Artjärvi (Artsjö)
202|Askola
203|Bromarv
204|Espoo (Esbo)
205|Hanko (Hangö)
206|Helsinki (Helsingfors)
207|Hyvinkää (Hyvinge)
208|Inkoo (Ingå)
209|Järvenpää
210|Karjaa (Karis)
211|Karjalohja (Karislojo)
212|Karkkila
213|Kauniainen (Grankulla)
214|Kerava (Kervo)
215|Kirkkonummi (Kyrkslätt)
216|Lapinjärvi (Lappträsk)
217|Liljendal
218|Lohja (Lojo)
219|Lohjan kunta (Lohjan mlk)
220|Loviisa (Lovisa)
221|Myrskylä (Mörskom)
222|Mäntsälä
223|Nummi-Pusula (Nummi)
224|Nurmijärvi
225|Orimattila
226|Pernaja (Perna)
227|Pohja (Pojo)
228|Pornainen (Borgnäs)
229|Porvoo (Borgå)
230|Porvoon mlk (Borgå lk)
231|Pukkila
232|Pusula
233|Ruotsinpyhtää (Strömfors)
234|Sammatti
235|Sipoo (Sibbo)
236|Siuntio (Sjundeå)
237|Snappertuna
238|Tammisaari (Ekenäs)
239|Tammisaaren mlk (Ekenäs lk)
240|Tenhola (Tenala)
241|Tuusula (Tusby)
242|Vantaa (Vanda)
243|Vihti
244|Raasepori
301|Asikkala
302|Eräjärvi
303|Forssa
304|Hattula
305|Hauho
306|Hausjärvi
307|Hollola
308|Humppila
309|Hämeenlinna (Tavastehus)
310|Janakkala
311|Jokioinen
312|Juupajoki
313|Kalvola
314|Kangasala
315|Hämeenkoski (Koski hl)
316|Kuhmalahti
317|Kuorevesi
318|Kuru
319|Kylmäkoski
320|Kärkölä
321|Lahti
322|Lammi
323|Lempäälä
324|Loppi
325|Luopioinen
326|Längelmäki
327|Mänttä
328|Nastola
329|Nokia
330|Orivesi
331|Padasjoki
332|Pirkkala
333|Pälkäne
334|Renko
335|Riihimäki
336|Ruovesi
337|Sahalahti
338|Somerniemi
339|Somero
340|Tammela
341|Tampere (Tammerfors)
342|Toijala
343|Tottijärvi
344|Tuulos
345|Urjala
346|Valkeakoski
347|Vesilahti
348|Viiala
349|Vilppula
350|Virrat
351|Ylöjärvi
352|Ypäjä
353|Hämeenkyrö (Tavastkyro)
354|Ikaalinen
355|Kihniö
356|Mouhijärvi
357|Parkano
358|Viljakkala
359|Akaa
360|Mänttä-Vilppula
401|Anttola
402|Enonkoski
403|Hartola
404|Haukivuori
405|Heinola
406|Heinolan mlk (Heinola lk)
407|Heinävesi
408|Hirvensalmi
409|Joroinen
410|Juva
411|Jäppilä
412|Kangaslampi
413|Kangasniemi
414|Kerimäki
415|Mikkeli (St. Michel)
416|Mikkelin mlk (St. Michel's lk)
417|Mäntyharju
418|Pertunmaa
419|Pieksämäki
420|Pieksänmaa (Pieksämäen mlk)
421|Punkaharju
422|Puumala
423|Rantasalmi
424|Ristiina
425|Savonlinna (Nyslott)
426|Savonranta
427|Sulkava
428|Sysmä
429|Virtasalmi
501|Anjala
502|Elimäki
503|Hamina (Fredrikshamn)
504|Iitti
505|Imatra
506|Jaala
507|Joutseno
508|Karhula
509|Kotka
510|Kouvola
511|Kuusankoski
512|Kymi (Kymmene)
513|Lappeenranta (Villmanstrand)
514|Lemi
515|Luumäki
516|Miehikkälä
517|Nuijamaa
518|Parikkala
519|Pyhtää (Pyttis)
520|Rautjärvi
521|Ruokolahti
522|Saari
523|Savitaipale
524|Sippola
525|Suomenniemi
526|Taipalsaari
527|Uudenkaarlepyyn mlk (Nykarleby lk)
528|Valkeala
529|Vehkalahti
530|Virolahti
531|Ylämaa
532|Anjalankoski
601|Alahärmä
602|Alajärvi
603|Alavus (Alavo)
604|Evijärvi
605|Halsua
606|Hankasalmi
607|Himanka
608|Ilmajoki
609|Isojoki (Stora)
610|Isokyrö (Storkyro)
611|Jalasjärvi
612|Joutsa
613|Jurva
614|Jyväskylä
615|Jyväskylän mlk (Jyväskylä lk)
616|Jämsä
617|Jämsänkoski
618|Kaarlela (Karleby)
619|Kannonkoski
620|Kannus
621|Karijoki (Bötom)
622|Karstula
623|Kaskinen (Kasköo)
624|Kauhajoki
625|Kauhava
626|Kaustinen (Kaustby)
627|Keuruu
628|Kinnula
629|Kivijärvi
630|Kokkola (Gamlakarleby)
631|Konginkangas
632|Konnevesi
633|Korpilahti
634|Korsnäs
635|Kortesjärvi
636|Kristiinankaupunki (Kristinestad)
637|Kruunupyy (Kronoby)
638|Kuhmoinen
639|Kuortane
640|Kurikka
641|Kyyjärvi
642|Kälviä
643|Laihia
644|Lappajärvi
645|Lapua (Lappo)
646|Laukaa
647|Lehtimäki
648|Leivonmäki
649|Lestijärvi
650|Lohtaja
651|Luhanka
652|Luoto (Larsmo)
653|Maalahti (Malax)
654|Maksamaa (Maxmo)
655|Multia
656|Mustasaari (Korsholm)
657|Muurame
658|Nurmo
659|Närpiö (Närpes)
660|Oravainen (Gravais)
661|Perho
662|Peräseinäjoki
663|Petäjävesi
664|Pietarsaari (Jakobstad)
665|Pedersöre (Pietarsaaren mlk)
666|Pihtipudas
667|Purmo
668|Pylkönmäki
669|Saarijärvi
670|Seinäjoki
671|Soini
672|Sumiainen
673|Suolahti
674|Säynätsalo
675|Teuva (Östermark)
676|Toholampi
677|Toivakka
678|Töysä
679|Ullava
680|Uurainen
681|Uusikaarlepyy (Nykarleby)
682|Vaasa (Vasa)
683|Veteli (Vetil)
684|Viitasaari
685|Vimpeli (Vindala)
686|Vähäkyrö (Lillkyro)
687|Vöyri (Vörå)
688|Ylihärmä
689|Ylistaro
690|Ähtäri
691|Ähtävä (Esse)
692|Äänekoski
693|Jepua (Jeppo)
694|Munsala
695|Uudenkaarlepyyn mlk
696|Vöyri-Maksamaa (Vörå-Maxmo)
701|Eno
702|Iisalmi
703|Ilomantsi
704|Joensuu
705|Juankoski
706|Juuka
707|Kaavi
708|Karttula
709|Keitele
710|Kesälahti
711|Kiihtelysvaara
712|Kitee
713|Kiuruvesi
714|Kontiolahti
715|Kuopio
716|Lapinlahti
717|Leppävirta
718|Lieksa
719|Liperi
720|Maaninka
721|Nilsiä
722|Nurmes
723|Outokumpu
724|Pielavesi
725|Polvijärvi
726|Pyhäselkä
727|Rautalampi
728|Rautavaara
729|Rääkkylä
730|Siilinjärvi
731|Sonkajärvi
732|Suonenjoki
733|Tervo
734|Tohmajärvi
735|Tuupovaara
736|Tuusniemi
737|Valtimo
738|Varkaus
739|Varpaisjärvi
740|Vehmersalmi
741|Vesanto
742|Vieremä
743|Värtsilä
801|Alavieska
802|Haapajärvi
803|Haapavesi
804|Hailuoto (Karlö)
805|Haukipudas
806|Hyrynsalmi
807|Ii
808|Kajaani
809|Kajaanin mlk (Kajaani lk)
810|Kalajoki
811|Kempele
812|Kestilä
813|Kiiminki
814|Kuhmo
815|Kuivaniemi
816|Kuusamo
817|Kärsämäki
818|Liminka
819|Lumijoki
820|Merijärvi
821|Muhos
822|Nivala
823|Oulainen
824|Oulu (Uleåborg)
825|Oulunsalo
826|Paltamo
827|Pattijoki
828|Piippola
829|Pudasjärvi
830|Pulkkila
831|Puolanka
832|Pyhäjoki
833|Pyhäjärvi
834|Pyhäntä
835|Raahe (Brahestad)
836|Rantsila
837|Reisjärvi
838|Ristijärvi
839|Ruukki
840|Sievi
841|Siikajoki
842|Sotkamo
843|Suomussalmi
844|Taivalkoski
845|Temmes
846|Tyrnävä
847|Utajärvi
848|Vaala
849|Vihanti
850|Vuolijoki
851|Yli-Ii
852|Ylikiiminki
853|Ylivieska
854|Siikalatva
901|Enontekiö
902|Inari (Enare)
903|Kemi
904|Keminmaa (Kemin mlk)
905|Kemijärvi
906|Kemijärven mlk
907|Kittilä
908|Kolari
909|Muonio
910|Pelkosenniemi
911|Pello
912|Posio
913|Ranua
914|Rovaniemi
915|Rovaniemen mlk (Rovaniemi lk)
916|Salla
917|Savukoski
918|Simo
919|Sodankylä
920|Tervola
921|Tornio (Torneå)
922|Utsjoki
923|Ylitornio (Övertorneå)
1|Brändö
2|Eckerö
3|Finström
4|Föglö
5|Geta
6|Hammarland
7|Jomala
8|Kumlinge
9|Kökar
10|Lemland
11|Lumparland
12|Maarianhamina (Mariehamn)
13|Saltvik
14|Sottunga
15|Sund
16|Vårdö
51|Märket Reef
@US_COUNTY/AK
Aleutians East|Aleutians East Borough
Aleutians West|Aleutians West Census Area
Anchorage|Anchorage Municipality
Bethel|Bethel Census Area
Bristol Bay|Bristol Bay Borough
Denali|Denali Borough
Dillingham|Dillingham Census Area
Fairbanks North Star|Fairbanks North Star Borough
Haines|Haines Borough
Hoonah-Angoon|Hoonah-Angoon Census Area
Juneau|Juneau City and Borough
Kenai Peninsula|Kenai Peninsula Borough
Ketchikan Gateway|Ketchikan Gateway Borough
Kodiak Island|Kodiak Island Borough
Lake and Peninsula|Lake and Peninsula Borough
Matanuska Susitna|Matanuska-Susitna Borough
Nome|Nome Census Area
North Slope|North Slope Borough
Northwest Arctic|Northwest Arctic Borough
Petersburg|Petersburg Census Area
Prince of Wales-Hyder|Prince of Wales-Hyder Census Area
Sitka|Sitka City and Borough
Skagway|Skagway Municipality
Southeast Fairbanks|Southeast Fairbanks Census Area
Valdez Cordova|Valdez-Cordova Census Area
Wade Hampton|Wade Hampton Census Area
Wrangell|Wrangell City and Borough
Yakutat|Yakutat City and Borough
Yukon Koyukuk|Yukon-Koyukuk Census Area
Prince Wales Ketchikan|Prince of Wales-Outer-Ketichikan Census Area
Skagway Hoonah Angoon|Skagway-Hoonah-Angoon Census Area
@US_COUNTY/AL
Autauga|Autauga
Baldwin|Baldwin
Barbour|Barbour
Bibb|Bibb
Blount|Blount
Bullock|Bullock
Butler|Butler
Calhoun|Calhoun
Chambers|Chambers
Cherokee|Cherokee
Chilton|Chilton
Choctaw|Choctaw
Clarke|Clarke
Clay|Clay
Cleburne|Cleburne
Coffee|Coffee
Colbert|Colbert
Conecuh|Conecuh
Coosa|Coosa
Covington|Covington
Crenshaw|Crenshaw
Cullman|Cullman
Dale|Dale
Dallas|Dallas
De Kalb|DeKalb
Elmore|Elmore
Escambia|Escambia
Etowah|Etowah
Fayette|Fayette
Franklin|Franklin
Geneva|Geneva
Greene|Greene
Hale|Hale
Henry|Henry
Houston|Houston
Jackson|Jackson
Jefferson|Jefferson
Lamar|Lamar
Lauderdale|Lauderdale
Lawrence|Lawrence
Lee|Lee
Limestone|Limestone
Lowndes|Lowndes
Macon|Macon
Madison|Madison
Marengo|Marengo
Marion|Marion
Marshall|Marshall
Mobile|Mobile
Monroe|Monroe
Montgomery|Montgomery
Morgan|Morgan
Perry|Perry
Pickens|Pickens
Pike|Pike
Randolph|Randolph
Russell|Russell
Saint Clair|St. Clair
Shelby|Shelby
Sumter|Sumter
Talladega|Talladega
Tallapoosa|Tallapoosa
Tuscaloosa|Tuscaloosa
Walker|Walker
Washington|Washington
Wilcox|Wilcox
Winston|Winston
@US_COUNTY/AR
Arkansas|Arkansas
Ashley|Ashley
Baxter|Baxter
Benton|Benton
Boone|Boone
Bradley|Bradley
Calhoun|Calhoun
Carroll|Carroll
Chicot|Chicot
Clark|Clark
Clay|Clay
Cleburne|Cleburne
Cleveland|Cleveland
Columbia|Columbia
Conway|Conway
Craighead|Craighead
Crawford|Crawford
Crittenden|Crittenden
Cross|Cross
Dallas|Dallas
Desha|Desha
Drew|Drew
Faulkner|Faulkner
Franklin|Franklin
Fulton|Fulton
Garland|Garland
Grant|Grant
Greene|Greene
Hempstead|Hempstead
Hot Spring|Hot Spring
Howard|Howard
Independence|Independence
Izard|Izard
Jackson|Jackson
Jefferson|Jefferson
Johnson|Johnson
Lafayette|Lafayette
Lawrence|Lawrence
Lee|Lee
Lincoln|Lincoln
Little River|Little River
Logan|Logan
Lonoke|Lonoke
Madison|Madison
Marion|Marion
Miller|Miller
Mississippi|Mississippi
Monroe|Monroe
Montgomery|Montgomery
Nevada|Nevada
Newton|Newton
Ouachita|Ouachita
Perry|Perry
Phillips|Phillips
Pike|Pike
Poinsett|Poinsett
Polk|Polk
Pope|Pope
Prairie|Prairie
Pulaski|Pulaski
Randolph|Randolph
Saint Francis|St. Francis
Saline|Saline
Scott|Scott
Searcy|Searcy
Sebastian|Sebastian
Sevier|Sevier
Sharp|Sharp
Stone|Stone
Union|Union
Van Buren|Van Buren
Washington|Washington
White|White
Woodruff|Woodruff
Yell|Yell
@US_COUNTY/AZ
Apache|Apache
Cochise|Cochise
Coconino|Coconino
Gila|Gila
Graham|Graham
Greenlee|Greenlee
La Paz|La Paz
Maricopa|Maricopa
Mohave|Mohave
Navajo|Navajo
Pima|Pima
Pinal|Pinal
Santa Cruz|Santa Cruz
Yavapai|Yavapai
Yuma|Yuma
@US_COUNTY/CA
Alameda|Alameda
Alpine|Alpine
Amador|Amador
Butte|Butte
Calaveras|Calaveras
Colusa|Colusa
Contra Costa|Contra Costa
Del Norte|Del Norte
El Dorado|El Dorado
Fresno|Fresno
Glenn|Glenn
Humboldt|Humboldt
Imperial|Imperial
Inyo|Inyo
Kern|Kern
Kings|Kings
Lake|Lake
Lassen|Lassen
Los Angeles|Los Angeles
Madera|Madera
Marin|Marin
Mariposa|Mariposa
Mendocino|Mendocino
Merced|Merced
Modoc|Modoc
Mono|Mono
Monterey|Monterey
Napa|Napa
Nevada|Nevada
Orange|Orange
Placer|Placer
Plumas|Plumas
Riverside|Riverside
Sacramento|Sacramento
San Benito|San Benito
San Bernardino|San Bernardino
San Diego|San Diego
San Francisco|San Francisco
San Joaquin|San Joaquin
San Luis Obispo|San Luis Obispo
San Mateo|San Mateo
Santa Barbara|Santa Barbara
Santa Clara|Santa Clara
Santa Cruz|Santa Cruz
Shasta|Shasta
Sierra|Sierra
Siskiyou|Siskiyou
Solano|Solano
Sonoma|Sonoma
Stanislaus|Stanislaus
Sutter|Sutter
Tehama|Tehama
Trinity|Trinity
Tulare|Tulare
Tuolumne|Tuolumne
Ventura|Ventura
Yolo|Yolo
Yuba|Yuba
@US_COUNTY/CO
Adams|Adams
Alamosa|Alamosa
Arapahoe|Arapahoe
Archuleta|Archuleta
Baca|Baca
Bent|Bent
Boulder|Boulder
Broomfield|Broomfield
Chaffee|Chaffee
Cheyenne|Cheyenne
Clear Creek|Clear Creek
Conejos|Conejos
Costilla|Costilla
Crowley|Crowley
Custer|Custer
Delta|Delta
Denver|Denver
Dolores|Dolores
Douglas|Douglas
Eagle|Eagle
El Paso|El Paso
Elbert|Elbert
Fremont|Fremont
Garfield|Garfield
Gilpin|Gilpin
Grand|Grand
Gunnison|Gunnison
Hinsdale|Hinsdale
Huerfano|Huerfano
Jackson|Jackson
Jefferson|Jefferson
Kiowa|Kiowa
Kit Carson|Kit Carson
La Plata|La Plata
Lake|Lake
Larimer|Larimer
Las Animas|Las Animas
Lincoln|Lincoln
Logan|Logan
Mesa|Mesa
Mineral|Mineral
Moffat|Moffat
Montezuma|Montezuma
Montrose|Montrose
Morgan|Morgan
Otero|Otero
Ouray|Ouray
Park|Park
Phillips|Phillips
Pitkin|Pitkin
Prowers|Prowers
Pueblo|Pueblo
Rio Blanco|Rio Blanco
Rio Grande|Rio Grande
Routt|Routt
Saguache|Saguache
San Juan|San Juan
San Miguel|San Miguel
Sedgwick|Sedgwick
Summit|Summit
Teller|Teller
Washington|Washington
Weld|Weld
Yuma|Yuma
@US_COUNTY/CT
Fairfield|Fairfield
Hartford|Hartford
Litchfield|Litchfield
Middlesex|Middlesex
New Haven|New Haven
New London|New London
Tolland|Tolland
Windham|Windham
@US_COUNTY/DE
Kent|Kent
New Castle|New Castle
Sussex|Sussex
@US_COUNTY/FL
Alachua|Alachua
Baker|Baker
Bay|Bay
Bradford|Bradford
Brevard|Brevard
Broward|Broward
Calhoun|Calhoun
Charlotte|Charlotte
Citrus|Citrus
Clay|Clay
Collier|Collier
Columbia|Columbia
De Soto|DeSoto
Dixie|Dixie
Duval|Duval
Escambia|Escambia
Flagler|Flagler
Franklin|Franklin
Gadsden|Gadsden
Gilchrist|Gilchrist
Glades|Glades
Gulf|Gulf
Hamilton|Hamilton
Hardee|Hardee
Hendry|Hendry
Hernando|Hernando
Highlands|Highlands
Hillsborough|Hillsborough
Holmes|Holmes
Indian River|Indian River
Jackson|Jackson
Jefferson|Jefferson
Lafayette|Lafayette
Lake|Lake
Lee|Lee
Leon|Leon
Levy|Levy
Liberty|Liberty
Madison|Madison
Manatee|Manatee
Marion|Marion
Martin|Martin
Miami-Dade|Miami-Dade
Monroe|Monroe
Nassau|Nassau
Okaloosa|Okaloosa
Okeechobee|Okeechobee
Orange|Orange
Osceola|Osceola
Palm Beach|Palm Beach
Pasco|Pasco
Pinellas|Pinellas
Polk|Polk
Putnam|Putnam
Saint Johns|St. Johns
Saint Lucie|St. Lucie
Santa Rosa|Santa Rosa
Sarasota|Sarasota
Seminole|Seminole
Sumter|Sumter
Suwannee|Suwannee
Taylor|Taylor
Union|Union
Volusia|Volusia
Wakulla|Wakulla
Walton|Walton
Washington|Washington
@US_COUNTY/GA
Appling|Appling
Atkinson|Atkinson
Bacon|Bacon
Baker|Baker
Baldwin|Baldwin
Banks|Banks
Barrow|Barrow
Bartow|Bartow
Ben Hill|Ben Hill
Berrien|Berrien
Bibb|Bibb
Bleckley|Bleckley
Brantley|Brantley
Brooks|Brooks
Bryan|Bryan
Bulloch|Bulloch
Burke|Burke
Butts|Butts
Calhoun|Calhoun
Camden|Camden
Candler|Candler
Carroll|Carroll
Catoosa|Catoosa
Charlton|Charlton
Chatham|Chatham
Chattahoochee|Chattahoochee
Chattooga|Chattooga
Cherokee|Cherokee
Clarke|Clarke
Clay|Clay
Clayton|Clayton
Clinch|Clinch
Cobb|Cobb
Coffee|Coffee
Colquitt|Colquitt
Columbia|Columbia
Cook|Cook
Coweta|Coweta
Crawford|Crawford
Crisp|Crisp
Dade|Dade
Dawson|Dawson
Decatur|Decatur
Dekalb|DeKalb
Dodge|Dodge
Dooly|Dooly
Dougherty|Dougherty
Douglas|Douglas
Early|Early
Echols|Echols
Effingham|Effingham
Elbert|Elbert
Emanuel|Emanuel
Evans|Evans
Fannin|Fannin
Fayette|Fayette
Floyd|Floyd
Forsyth|Forsyth
Franklin|Franklin
Fulton|Fulton
Gilmer|Gilmer
Glascock|Glascock
Glynn|Glynn
Gordon|Gordon
Grady|Grady
Greene|Greene
Gwinnett|Gwinnett
Habersham|Habersham
Hall|Hall
Hancock|Hancock
Haralson|Haralson
Harris|Harris
Hart|Hart
Heard|Heard
Henry|Henry
Houston|Houston
Irwin|Irwin
Jackson|Jackson
Jasper|Jasper
Jeff Davis|Jeff Davis
Jefferson|Jefferson
Jenkins|Jenkins
Johnson|Johnson
Jones|Jones
Lamar|Lamar
Lanier|Lanier
Laurens|Laurens
Lee|Lee
Liberty|Liberty
Lincoln|Lincoln
Long|Long
Lowndes|Lowndes
Lumpkin|Lumpkin
Macon|Macon
Madison|Madison
Marion|Marion
McDuffie|McDuffie
McIntosh|McIntosh
Meriwether|Meriwether
Miller|Miller
Mitchell|Mitchell
Monroe|Monroe
Montgomery|Montgomery
Morgan|Morgan
Murray|Murray
Muscogee|Muscogee
Newton|Newton
Oconee|Oconee
Oglethorpe|Oglethorpe
Paulding|Paulding
Peach|Peach
Pickens|Pickens
Pierce|Pierce
Pike|Pike
Polk|Polk
Pulaski|Pulaski
Putnam|Putnam
Quitman|Quitman
Rabun|Rabun
Randolph|Randolph
Richmond|Richmond
Rockdale|Rockdale
Schley|Schley
Screven|Screven
Seminole|Seminole
Spalding|Spalding
Stephens|Stephens
Stewart|Stewart
Sumter|Sumter
Talbot|Talbot
Taliaferro|Taliaferro
Tattnall|Tattnall
Taylor|Taylor
Telfair|Telfair
Terrell|Terrell
Thomas|Thomas
Tift|Tift
Toombs|Toombs
Towns|Towns
Treutlen|Treutlen
Troup|Troup
Turner|Turner
Twiggs|Twiggs
Union|Union
Upson|Upson
Walker|Walker
Walton|Walton
Ware|Ware
Warren|Warren
Washington|Washington
Wayne|Wayne
Webster|Webster
Wheeler|Wheeler
White|White
Whitfield|Whitfield
Wilcox|Wilcox
Wilkes|Wilkes
Wilkinson|Wilkinson
Worth|Worth
@US_COUNTY/HI
Hawaii|Hawaii
Honolulu|Honolulu
Kalawao|Kalawao
Kauai|Kauai
Maui|Maui
@US_COUNTY/IA
Adair|Adair
Adams|Adams
Allamakee|Allamakee
Appanoose|Appanoose
Audubon|Audubon
Benton|Benton
Black Hawk|Black Hawk
Boone|Boone
Bremer|Bremer
Buchanan|Buchanan
Buena Vista|Buena Vista
Butler|Butler
Calhoun|Calhoun
Carroll|Carroll
Cass|Cass
Cedar|Cedar
Cerro Gordo|Cerro Gordo
Cherokee|Cherokee
Chickasaw|Chickasaw
Clarke|Clarke
Clay|Clay
Clayton|Clayton
Clinton|Clinton
Crawford|Crawford
Dallas|Dallas
Davis|Davis
Decatur|Decatur
Delaware|Delaware
Des Moines|Des Moines
Dickinson|Dickinson
Dubuque|Dubuque
Emmet|Emmet
Fayette|Fayette
Floyd|Floyd
Franklin|Franklin
Fremont|Fremont
Greene|Greene
Grundy|Grundy
Guthrie|Guthrie
Hamilton|Hamilton
Hancock|Hancock
Hardin|Hardin
Harrison|Harrison
Henry|Henry
Howard|Howard
Humboldt|Humboldt
Ida|Ida
Iowa|Iowa
Jackson|Jackson
Jasper|Jasper
Jefferson|Jefferson
Johnson|Johnson
Jones|Jones
Keokuk|Keokuk
Kossuth|Kossuth
Lee|Lee
Linn|Linn
Louisa|Louisa
Lucas|Lucas
Lyon|Lyon
Madison|Madison
Mahaska|Mahaska
Marion|Marion
Marshall|Marshall
Mills|Mills
Mitchell|Mitchell
Monona|Monona
Monroe|Monroe
Montgomery|Montgomery
Muscatine|Muscatine
Obrien|O'Brien
Osceola|Osceola
Page|Page
Palo Alto|Palo Alto
Plymouth|Plymouth
Pocahontas|Pocahontas
Polk|Polk
Pottawattamie|Pottawattamie
Poweshiek|Poweshiek
Ringgold|Ringgold
Sac|Sac
Scott|Scott
Shelby|Shelby
Sioux|Sioux
Story|Story
Tama|Tama
Taylor|Taylor
Union|Union
Van Buren|Van Buren
Wapello|Wapello
Warren|Warren
Washington|Washington
Wayne|Wayne
Webster|Webster
Winnebago|Winnebago
Winneshiek|Winneshiek
Woodbury|Woodbury
Worth|Worth
Wright|Wright
@US_COUNTY/ID
Ada|Ada
Adams|Adams
Bannock|Bannock
Bear Lake|Bear Lake
Benewah|Benewah
Bingham|Bingham
Blaine|Blaine
Boise|Boise
Bonner|Bonner
Bonneville|Bonneville
Boundary|Boundary
Butte|Butte
Camas|Camas
Canyon|Canyon
Caribou|Caribou
Cassia|Cassia
Clark|Clark
Clearwater|Clearwater
Custer|Custer
Elmore|Elmore
Franklin|Franklin
Fremont|Fremont
Gem|Gem
Gooding|Gooding
Idaho|Idaho
Jefferson|Jefferson
Jerome|Jerome
Kootenai|Kootenai
Latah|Latah
Lemhi|Lemhi
Lewis|Lewis
Lincoln|Lincoln
Madison|Madison
Minidoka|Minidoka
Nez Perce|Nez Perce
Oneida|Oneida
Owyhee|Owyhee
Payette|Payette
Power|Power
Shoshone|Shoshone
Teton|Teton
Twin Falls|Twin Falls
Valley|Valley
Washington|Washington
@US_COUNTY/IL
Adams|Adams
Alexander|Alexander
Bond|Bond
Boone|Boone
Brown|Brown
Bureau|Bureau
Calhoun|Calhoun
Carroll|Carroll
Cass|Cass
Champaign|Champaign
Christian|Christian
Clark|Clark
Clay|Clay
Clinton|Clinton
Coles|Coles
Cook|Cook
Crawford|Crawford
Cumberland|Cumberland
De Kalb|DeKalb
Dewitt|DeWitt
Douglas|Douglas
Du Page|DuPage
Edgar|Edgar
Edwards|Edwards
Effingham|Effingham
Fayette|Fayette
Ford|Ford
Franklin|Franklin
Fulton|Fulton
Gallatin|Gallatin
Greene|Greene
Grundy|Grundy
Hamilton|Hamilton
Hancock|Hancock
Hardin|Hardin
Henderson|Henderson
Henry|Henry
Iroquois|Iroquois
Jackson|Jackson
Jasper|Jasper
Jefferson|Jefferson
Jersey|Jersey
Jo Daviess|Jo Daviess
Johnson|Johnson
Kane|Kane
Kankakee|Kankakee
Kendall|Kendall
Knox|Knox
La Salle|LaSalle
Lake|Lake
Lawrence|Lawrence
Lee|Lee
Livingston|Livingston
Logan|Logan
Macon|Macon
Macoupin|Macoupin
Madison|Madison
Marion|Marion
Marshall|Marshall
Mason|Mason
Massac|Massac
McDonough|McDonough
McHenry|McHenry
McLean|McLean
Menard|Menard
Mercer|Mercer
Monroe|Monroe
Montgomery|Montgomery
Morgan|Morgan
Moultrie|Moultrie
Ogle|Ogle
Peoria|Peoria
Perry|Perry
Piatt|Piatt
Pike|Pike
Pope|Pope
Pulaski|Pulaski
Putnam|Putnam
Randolph|Randolph
Richland|Richland
Rock Island|Rock Island
Saint Clair|St. Clair
Saline|Saline
Sangamon|Sangamon
Schuyler|Schuyler
Scott|Scott
Shelby|Shelby
Stark|Stark
Stephenson|Stephenson
Tazewell|Tazewell
Union|Union
Vermilion|Vermilion
Wabash|Wabash
Warren|Warren
Washington|Washington
Wayne|Wayne
White|White
Whiteside|Whiteside
Will|Will
Williamson|Williamson
Winnebago|Winnebago
Woodford|Woodford
@US_COUNTY/IN
Adams|Adams
Allen|Allen
Bartholomew|Bartholomew
Benton|Benton
Blackford|Blackford
Boone|Boone
Brown|Brown
Carroll|Carroll
Cass|Cass
Clark|Clark
Clay|Clay
Clinton|Clinton
Crawford|Crawford
Daviess|Daviess
De Kalb|DeKalb
Dearborn|Dearborn
Decatur|Decatur
Delaware|Delaware
Dubois|Dubois
Elkhart|Elkhart
Fayette|Fayette
Floyd|Floyd
Fountain|Fountain
Franklin|Franklin
Fulton|Fulton
Gibson|Gibson
Grant|Grant
Greene|Greene
Hamilton|Hamilton
Hancock|Hancock
Harrison|Harrison
Hendricks|Hendricks
Henry|Henry
Howard|Howard
Huntington|Huntington
Jackson|Jackson
Jasper|Jasper
Jay|Jay
Jefferson|Jefferson
Jennings|Jennings
Johnson|Johnson
Knox|Knox
Kosciusko|Kosciusko
La Porte|LaPorte
Lagrange|LaGrange
Lake|Lake
Lawrence|Lawrence
Madison|Madison
Marion|Marion
Marshall|Marshall
Martin|Martin
Miami|Miami
Monroe|Monroe
Montgomery|Montgomery
Morgan|Morgan
Newton|Newton
Noble|Noble
Ohio|Ohio
Orange|Orange
Owen|Owen
Parke|Parke
Perry|Perry
Pike|Pike
Porter|Porter
Posey|Posey
Pulaski|Pulaski
Putnam|Putnam
Randolph|Randolph
Ripley|Ripley
Rush|Rush
Scott|Scott
Shelby|Shelby
Spencer|Spencer
St Joseph|St. Joseph
Starke|Starke
Steuben|Steuben
Sullivan|Sullivan
Switzerland|Switzerland
Tippecanoe|Tippecanoe
Tipton|Tipton
Union|Union
Vanderburgh|Vanderburgh
Vermillion|Vermillion
Vigo|Vigo
Wabash|Wabash
Warren|Warren
Warrick|Warrick
Washington|Washington
Wayne|Wayne
Wells|Wells
White|White
Whitley|Whitley
@US_COUNTY/KS
Allen|Allen
Anderson|Anderson
Atchison|Atchison
Barber|Barber
Barton|Barton
Bourbon|Bourbon
Brown|Brown
Butler|Butler
Chase|Chase
Chautauqua|Chautauqua
Cherokee|Cherokee
Cheyenne|Cheyenne
Clark|Clark
Clay|Clay
Cloud|Cloud
Coffey|Coffey
Comanche|Comanche
Cowley|Cowley
Crawford|Crawford
Decatur|Decatur
Dickinson|Dickinson
Doniphan|Doniphan
Douglas|Douglas
Edwards|Edwards
Elk|Elk
Ellis|Ellis
Ellsworth|Ellsworth
Finney|Finney
Ford|Ford
Franklin|Franklin
Geary|Geary
Gove|Gove
Graham|Graham
Grant|Grant
Gray|Gray
Greeley|Greeley
Greenwood|Greenwood
Hamilton|Hamilton
Harper|Harper
Harvey|Harvey
Haskell|Haskell
Hodgeman|Hodgeman
Jackson|Jackson
Jefferson|Jefferson
Jewell|Jewell
Johnson|Johnson
Kearny|Kearny
Kingman|Kingman
Kiowa|Kiowa
Labette|Labette
Lane|Lane
Leavenworth|Leavenworth
Lincoln|Lincoln
Linn|Linn
Logan|Logan
Lyon|Lyon
Marion|Marion
Marshall|Marshall
McPherson|McPherson
Meade|Meade
Miami|Miami
Mitchell|Mitchell
Montgomery|Montgomery
Morris|Morris
Morton|Morton
Nemaha|Nemaha
Neosho|Neosho
Ness|Ness
Norton|Norton
Osage|Osage
Osborne|Osborne
Ottawa|Ottawa
Pawnee|Pawnee
Phillips|Phillips
Pottawatomie|Pottawatomie
Pratt|Pratt
Rawlins|Rawlins
Reno|Reno
Republic|Republic
Rice|Rice
Riley|Riley
Rooks|Rooks
Rush|Rush
Russell|Russell
Saline|Saline
Scott|Scott
Sedgwick|Sedgwick
Seward|Seward
Shawnee|Shawnee
Sheridan|Sheridan
Sherman|Sherman
Smith|Smith
Stafford|Stafford
Stanton|Stanton
Stevens|Stevens
Sumner|Sumner
Thomas|Thomas
Trego|Trego
Wabaunsee|Wabaunsee
Wallace|Wallace
Washington|Washington
Wichita|Wichita
Wilson|Wilson
Woodson|Woodson
Wyandotte|Wyandotte
@US_COUNTY/KY
Adair|Adair
Allen|Allen
Anderson|Anderson
Ballard|Ballard
Barren|Barren
Bath|Bath
Bell|Bell
Boone|Boone
Bourbon|Bourbon
Boyd|Boyd
Boyle|Boyle
Bracken|Bracken
Breathitt|Breathitt
Breckinridge|Breckinridge
Bullitt|Bullitt
Butler|Butler
Caldwell|Caldwell
Calloway|Calloway
Campbell|Campbell
Carlisle|Carlisle
Carroll|Carroll
Carter|Carter
Casey|Casey
Christian|Christian
Clark|Clark
Clay|Clay
Clinton|Clinton
Crittenden|Crittenden
Cumberland|Cumberland
Daviess|Daviess
Edmonson|Edmonson
Elliott|Elliott
Estill|Estill
Fayette|Fayette
Fleming|Fleming
Floyd|Floyd
Franklin|Franklin
Fulton|Fulton
Gallatin|Gallatin
Garrard|Garrard
Grant|Grant
Graves|Graves
Grayson|Grayson
Green|Green
Greenup|Greenup
Hancock|Hancock
Hardin|Hardin
Harlan|Harlan
Harrison|Harrison
Hart|Hart
Henderson|Henderson
Henry|Henry
Hickman|Hickman
Hopkins|Hopkins
Jackson|Jackson
Jefferson|Jefferson
Jessamine|Jessamine
Johnson|Johnson
Kenton|Kenton
Knott|Knott
Knox|Knox
Larue|Larue
Laurel|Laurel
Lawrence|Lawrence
Lee|Lee
Leslie|Leslie
Letcher|Letcher
Lewis|Lewis
Lincoln|Lincoln
Livingston|Livingston
Logan|Logan
Lyon|Lyon
Madison|Madison
Magoffin|Magoffin
Marion|Marion
Marshall|Marshall
Martin|Martin
Mason|Mason
McCracken|McCracken
McCreary|McCreary
McLean|McLean
Meade|Meade
Menifee|Menifee
Mercer|Mercer
Metcalfe|Metcalfe
Monroe|Monroe
Montgomery|Montgomery
Morgan|Morgan
Muhlenberg|Muhlenberg
Nelson|Nelson
Nicholas|Nicholas
Ohio|Ohio
Oldham|Oldham
Owen|Owen
Owsley|Owsley
Pendleton|Pendleton
Perry|Perry
Pike|Pike
Powell|Powell
Pulaski|Pulaski
Robertson|Robertson
Rockcastle|Rockcastle
Rowan|Rowan
Russell|Russell
Scott|Scott
Shelby|Shelby
Simpson|Simpson
Spencer|Spencer
Taylor|Taylor
Todd|Todd
Trigg|Trigg
Trimble|Trimble
Union|Union
Warren|Warren
Washington|Washington
Wayne|Wayne
Webster|Webster
Whitley|Whitley
Wolfe|Wolfe
Woodford|Woodford
@US_COUNTY/LA
Acadia|Acadia
Allen|Allen
Ascension|Ascension
Assumption|Assumption
Avoyelles|Avoyelles
Beauregard|Beauregard
Bienville|Bienville
Bossier|Bossier
Caddo|Caddo
Calcasieu|Calcasieu
Caldwell|Caldwell
Cameron|Cameron
Catahoula|Catahoula
Claiborne|Claiborne
Concordia|Concordia
De Soto|De Soto
East Baton Rouge|East Baton Rouge
East Carroll|East Carroll
East Feliciana|East Feliciana
Evangeline|Evangeline
Franklin|Franklin
Grant|Grant
Iberia|Iberia
Iberville|Iberville
Jackson|Jackson
Jefferson|Jefferson
Jefferson Davis|Jefferson Davis
La Salle|LaSalle
Lafayette|Lafayette
Lafourche|Lafourche
Lincoln|Lincoln
Livingston|Livingston
Madison|Madison
Morehouse|Morehouse
Natchitoches|Natchitoches
Orleans|Orleans
Ouachita|Ouachita
Plaquemines|Plaquemines
Pointe Coupee|Pointe Coupee
Rapides|Rapides
Red River|Red River
Richland|Richland
Sabine|Sabine
Saint Bernard|St. Bernard
Saint Charles|St. Charles
Saint Helena|St. Helena
Saint James|St. James
Saint Landry|St. Landry
Saint Martin|St. Martin
Saint Mary|St. Mary
Saint Tammany|St. Tammany
St John the Baptist|St. John the Baptist
Tangipahoa|Tangipahoa
Tensas|Tensas
Terrebonne|Terrebonne
Union|Union
Vermilion|Vermilion
Vernon|Vernon
Washington|Washington
Webster|Webster
West Baton Rouge|West Baton Rouge
West Carroll|West Carroll
West Feliciana|West Feliciana
Winn|Winn
@US_COUNTY/MA
Barnstable|Barnstable
Berkshire|Berkshire
Bristol|Bristol
Dukes|Dukes
Essex|Essex
Franklin|Franklin
Hampden|Hampden
Hampshire|Hampshire
Middlesex|Middlesex
Nantucket|Nantucket
Norfolk|Norfolk
Plymouth|Plymouth
Suffolk|Suffolk
Worcester|Worcester
@US_COUNTY/MD
Allegany|Allegany
Anne Arundel|Anne Arundel
Baltimore|Baltimore
Baltimore City|Baltimore City
Calvert|Calvert
Caroline|Caroline
Carroll|Carroll
Cecil|Cecil
Charles|Charles
Dorchester|Dorchester
Frederick|Frederick
Garrett|Garrett
Harford|Harford
Howard|Howard
Kent|Kent
Montgomery|Montgomery
Prince Georges|Prince George's
Queen Annes|Queen Anne's
Saint Marys|St. Mary's
Somerset|Somerset
Talbot|Talbot
Washington|Washington
Wicomico|Wicomico
Worcester|Worcester
@US_COUNTY/ME
Androscoggin|Androscoggin
Aroostook|Aroostook
Cumberland|Cumberland
Franklin|Franklin
Hancock|Hancock
Kennebec|Kennebec
Knox|Knox
Lincoln|Lincoln
Oxford|Oxford
Penobscot|Penobscot
Piscataquis|Piscataquis
Sagadahoc|Sagadahoc
Somerset|Somerset
Waldo|Waldo
Washington|Washington
York|York
@US_COUNTY/MI
Alcona|Alcona
Alger|Alger
Allegan|Allegan
Alpena|Alpena
Antrim|Antrim
Arenac|Arenac
Baraga|Baraga
Barry|Barry
Bay|Bay
Benzie|Benzie
Berrien|Berrien
Branch|Branch
Calhoun|Calhoun
Cass|Cass
Charlevoix|Charlevoix
Cheboygan|Cheboygan
Chippewa|Chippewa
Clare|Clare
Clinton|Clinton
Crawford|Crawford
Delta|Delta
Dickinson|Dickinson
Eaton|Eaton
Emmet|Emmet
Genesee|Genesee
Gladwin|Gladwin
Gogebic|Gogebic
Grand Traverse|Grand Traverse
Gratiot|Gratiot
Hillsdale|Hillsdale
Houghton|Houghton
Huron|Huron
Ingham|Ingham
Ionia|Ionia
Iosco|Iosco
Iron|Iron
Isabella|Isabella
Jackson|Jackson
Kalamazoo|Kalamazoo
Kalkaska|Kalkaska
Kent|Kent
Keweenaw|Keweenaw
Lake|Lake
Lapeer|Lapeer
Leelanau|Leelanau
Lenawee|Lenawee
Livingston|Livingston
Luce|Luce
Mackinac|Mackinac
Macomb|Macomb
Manistee|Manistee
Marquette|Marquette
Mason|Mason
Mecosta|Mecosta
Menominee|Menominee
Midland|Midland
Missaukee|Missaukee
Monroe|Monroe
Montcalm|Montcalm
Montmorency|Montmorency
Muskegon|Muskegon
Newaygo|Newaygo
Oakland|Oakland
Oceana|Oceana
Ogemaw|Ogemaw
Ontonagon|Ontonagon
Osceola|Osceola
Oscoda|Oscoda
Otsego|Otsego
Ottawa|Ottawa
Presque Isle|Presque Isle
Roscommon|Roscommon
Saginaw|Saginaw
Saint Clair|St. Clair
Saint Joseph|St. Joseph
Sanilac|Sanilac
Schoolcraft|Schoolcraft
Shiawassee|Shiawassee
Tuscola|Tuscola
Van Buren|Van Buren
Washtenaw|Washtenaw
Wayne|Wayne
Wexford|Wexford
@US_COUNTY/MN
Aitkin|Aitkin
Anoka|Anoka
Becker|Becker
Beltrami|Beltrami
Benton|Benton
Big Stone|Big Stone
Blue Earth|Blue Earth
Brown|Brown
Carlton|Carlton
Carver|Carver
Cass|Cass
Chippewa|Chippewa
Chisago|Chisago
Clay|Clay
Clearwater|Clearwater
Cook|Cook
Cottonwood|Cottonwood
Crow Wing|Crow Wing
Dakota|Dakota
Dodge|Dodge
Douglas|Douglas
Faribault|Faribault
Fillmore|Fillmore
Freeborn|Freeborn
Goodhue|Goodhue
Grant|Grant
Hennepin|Hennepin
Houston|Houston
Hubbard|Hubbard
Isanti|Isanti
Itasca|Itasca
Jackson|Jackson
Kanabec|Kanabec
Kandiyohi|Kandiyohi
Kittson|Kittson
Koochiching|Koochiching
Lac Qui Parle|Lac qui Parle
Lake|Lake
Lake of the Woods|Lake of the Woods
Le Sueur|Le Sueur
Lincoln|Lincoln
Lyon|Lyon
Mahnomen|Mahnomen
Marshall|Marshall
Martin|Martin
McLeod|McLeod
Meeker|Meeker
Mille Lacs|Mille Lacs
Morrison|Morrison
Mower|Mower
Murray|Murray
Nicollet|Nicollet
Nobles|Nobles
Norman|Norman
Olmsted|Olmsted
Otter Tail|Otter Tail
Pennington|Pennington
Pine|Pine
Pipestone|Pipestone
Polk|Polk
Pope|Pope
Ramsey|Ramsey
Red Lake|Red Lake
Redwood|Redwood
Renville|Renville
Rice|Rice
Rock|Rock
Roseau|Roseau
Saint Louis|St. Louis
Scott|Scott
Sherburne|Sherburne
Sibley|Sibley
Stearns|Stearns
Steele|Steele
Stevens|Stevens
Swift|Swift
Todd|Todd
Traverse|Traverse
Wabasha|Wabasha
Wadena|Wadena
Waseca|Waseca
Washington|Washington
Watonwan|Watonwan
Wilkin|Wilkin
Winona|Winona
Wright|Wright
Yellow Medicine|Yellow Medicine
@US_COUNTY/MO
Adair|Adair
Andrew|Andrew
Atchison|Atchison
Audrain|Audrain
Barry|Barry
Barton|Barton
Bates|Bates
Benton|Benton
Bollinger|Bollinger
Boone|Boone
Buchanan|Buchanan
Butler|Butler
Caldwell|Caldwell
Callaway|Callaway
Camden|Camden
Cape Girardeau|Cape Girardeau
Carroll|Carroll
Carter|Carter
Cass|Cass
Cedar|Cedar
Chariton|Chariton
Christian|Christian
Clark|Clark
Clay|Clay
Clinton|Clinton
Cole|Cole
Cooper|Cooper
Crawford|Crawford
Dade|Dade
Dallas|Dallas
Daviess|Daviess
Dekalb|DeKalb
Dent|Dent
Douglas|Douglas
Dunklin|Dunklin
Franklin|Franklin
Gasconade|Gasconade
Gentry|Gentry
Greene|Greene
Grundy|Grundy
Harrison|Harrison
Henry|Henry
Hickory|Hickory
Holt|Holt
Howard|Howard
Howell|Howell
Iron|Iron
Jackson|Jackson
Jasper|Jasper
Jefferson|Jefferson
Johnson|Johnson
Knox|Knox
Laclede|Laclede
Lafayette|Lafayette
Lawrence|Lawrence
Lewis|Lewis
Lincoln|Lincoln
Linn|Linn
Livingston|Livingston
Macon|Macon
Madison|Madison
Maries|Maries
Marion|Marion
McDonald|McDonald
Mercer|Mercer
Miller|Miller
Mississippi|Mississippi
Moniteau|Moniteau
Monroe|Monroe
Montgomery|Montgomery
Morgan|Morgan
New Madrid|New Madrid
Newton|Newton
Nodaway|Nodaway
Oregon|Oregon
Osage|Osage
Ozark|Ozark
Pemiscot|Pemiscot
Perry|Perry
Pettis|Pettis
Phelps|Phelps
Pike|Pike
Platte|Platte
Polk|Polk
Pulaski|Pulaski
Putnam|Putnam
Ralls|Ralls
Randolph|Randolph
Ray|Ray
Reynolds|Reynolds
Ripley|Ripley
Saint Charles|St. Charles
Saint Clair|St. Clair
Saint Francois|St. Francois
Saint Louis|St. Louis
Saint Louis City|St. Louis City
Sainte Genevieve|Ste. Genevieve
Saline|Saline
Schuyler|Schuyler
Scotland|Scotland
Scott|Scott
Shannon|Shannon
Shelby|Shelby
Stoddard|Stoddard
Stone|Stone
Sullivan|Sullivan
Taney|Taney
Texas|Texas
Vernon|Vernon
Warren|Warren
Washington|Washington
Wayne|Wayne
Webster|Webster
Worth|Worth
Wright|Wright
@US_COUNTY/MS
Adams|Adams
Alcorn|Alcorn
Amite|Amite
Attala|Attala
Benton|Benton
Bolivar|Bolivar
Calhoun|Calhoun
Carroll|Carroll
Chickasaw|Chickasaw
Choctaw|Choctaw
Claiborne|Claiborne
Clarke|Clarke
Clay|Clay
Coahoma|Coahoma
Copiah|Copiah
Covington|Covington
De Soto|DeSoto
Forrest|Forrest
Franklin|Franklin
George|George
Greene|Greene
Grenada|Grenada
Hancock|Hancock
Harrison|Harrison
Hinds|Hinds
Holmes|Holmes
Humphreys|Humphreys
Issaquena|Issaquena
Itawamba|Itawamba
Jackson|Jackson
Jasper|Jasper
Jefferson|Jefferson
Jefferson Davis|Jefferson Davis
Jones|Jones
Kemper|Kemper
Lafayette|Lafayette
Lamar|Lamar
Lauderdale|Lauderdale
Lawrence|Lawrence
Leake|Leake
Lee|Lee
Leflore|Leflore
Lincoln|Lincoln
Lowndes|Lowndes
Madison|Madison
Marion|Marion
Marshall|Marshall
Monroe|Monroe
Montgomery|Montgomery
Neshoba|Neshoba
Newton|Newton
Noxubee|Noxubee
Oktibbeha|Oktibbeha
Panola|Panola
Pearl River|Pearl River
Perry|Perry
Pike|Pike
Pontotoc|Pontotoc
Prentiss|Prentiss
Quitman|Quitman
Rankin|Rankin
Scott|Scott
Sharkey|Sharkey
Simpson|Simpson
Smith|Smith
Stone|Stone
Sunflower|Sunflower
Tallahatchie|Tallahatchie
Tate|Tate
Tippah|Tippah
Tishomingo|Tishomingo
Tunica|Tunica
Union|Union
Walthall|Walthall
Warren|Warren
Washington|Washington
Wayne|Wayne
Webster|Webster
Wilkinson|Wilkinson
Winston|Winston
Yalobusha|Yalobusha
Yazoo|Yazoo
@US_COUNTY/MT
Beaverhead|Beaverhead
Big Horn|Big Horn
Blaine|Blaine
Broadwater|Broadwater
Carbon|Carbon
Carter|Carter
Cascade|Cascade
Chouteau|Chouteau
Custer|Custer
Daniels|Daniels
Dawson|Dawson
Deer Lodge|Deer Lodge
Fallon|Fallon
Fergus|Fergus
Flathead|Flathead
Gallatin|Gallatin
Garfield|Garfield
Glacier|Glacier
Golden Valley|Golden Valley
Granite|Granite
Hill|Hill
Jefferson|Jefferson
Judith Basin|Judith Basin
Lake|Lake
Lewis and Clark|Lewis and Clark
Liberty|Liberty
Lincoln|Lincoln
Madison|Madison
McCone|McCone
Meagher|Meagher
Mineral|Mineral
Missoula|Missoula
Musselshell|Musselshell
Park|Park
Petroleum|Petroleum
Phillips|Phillips
Pondera|Pondera
Powder River|Powder River
Powell|Powell
Prairie|Prairie
Ravalli|Ravalli
Richland|Richland
Roosevelt|Roosevelt
Rosebud|Rosebud
Sanders|Sanders
Sheridan|Sheridan
Silver Bow|Silver Bow
Stillwater|Stillwater
Sweet Grass|Sweet Grass
Teton|Teton
Toole|Toole
Treasure|Treasure
Valley|Valley
Wheatland|Wheatland
Wibaux|Wibaux
Yellowstone|Yellowstone
@US_COUNTY/NC
Alamance|Alamance
Alexander|Alexander
Alleghany|Alleghany
Anson|Anson
Ashe|Ashe
Avery|Avery
Beaufort|Beaufort
Bertie|Bertie
Bladen|Bladen
Brunswick|Brunswick
Buncombe|Buncombe
Burke|Burke
Cabarrus|Cabarrus
Caldwell|Caldwell
Camden|Camden
Carteret|Carteret
Caswell|Caswell
Catawba|Catawba
Chatham|Chatham
Cherokee|Cherokee
Chowan|Chowan
Clay|Clay
Cleveland|Cleveland
Columbus|Columbus
Craven|Craven
Cumberland|Cumberland
Currituck|Currituck
Dare|Dare
Davidson|Davidson
Davie|Davie
Duplin|Duplin
Durham|Durham
Edgecombe|Edgecombe
Forsyth|Forsyth
Franklin|Franklin
Gaston|Gaston
Gates|Gates
Graham|Graham
Granville|Granville
Greene|Greene
Guilford|Guilford
Halifax|Halifax
Harnett|Harnett
Haywood|Haywood
Henderson|Henderson
Hertford|Hertford
Hoke|Hoke
Hyde|Hyde
Iredell|Iredell
Jackson|Jackson
Johnston|Johnston
Jones|Jones
Lee|Lee
Lenoir|Lenoir
Lincoln|Lincoln
Macon|Macon
Madison|Madison
Martin|Martin
McDowell|McDowell
Mecklenburg|Mecklenburg
Mitchell|Mitchell
Montgomery|Montgomery
Moore|Moore
Nash|Nash
New Hanover|New Hanover
Northampton|Northampton
Onslow|Onslow
Orange|Orange
Pamlico|Pamlico
Pasquotank|Pasquotank
Pender|Pender
Perquimans|Perquimans
Person|Person
Pitt|Pitt
Polk|Polk
Randolph|Randolph
Richmond|Richmond
Robeson|Robeson
Rockingham|Rockingham
Rowan|Rowan
Rutherford|Rutherford
Sampson|Sampson
Scotland|Scotland
Stanly|Stanly
Stokes|Stokes
Surry|Surry
Swain|Swain
Transylvania|Transylvania
Tyrrell|Tyrrell
Union|Union
Vance|Vance
Wake|Wake
Warren|Warren
Washington|Washington
Watauga|Watauga
Wayne|Wayne
Wilkes|Wilkes
Wilson|Wilson
Yadkin|Yadkin
Yancey|Yancey
@US_COUNTY/ND
Adams|Adams
Barnes|Barnes
Benson|Benson
Billings|Billings
Bottineau|Bottineau
Bowman|Bowman
Burke|Burke
Burleigh|Burleigh
Cass|Cass
Cavalier|Cavalier
Dickey|Dickey
Divide|Divide
Dunn|Dunn
Eddy|Eddy
Emmons|Emmons
Foster|Foster
Golden Valley|Golden Valley
Grand Forks|Grand Forks
Grant|Grant
Griggs|Griggs
Hettinger|Hettinger
Kidder|Kidder
Lamoure|LaMoure
Logan|Logan
McHenry|McHenry
McIntosh|McIntosh
McKenzie|McKenzie
McLean|McLean
Mercer|Mercer
Morton|Morton
Mountrail|Mountrail
Nelson|Nelson
Oliver|Oliver
Pembina|Pembina
Pierce|Pierce
Ramsey|Ramsey
Ransom|Ransom
Renville|Renville
Richland|Richland
Rolette|Rolette
Sargent|Sargent
Sheridan|Sheridan
Sioux|Sioux
Slope|Slope
Stark|Stark
Steele|Steele
Stutsman|Stutsman
Towner|Towner
Traill|Traill
Walsh|Walsh
Ward|Ward
Wells|Wells
Williams|Williams
@US_COUNTY/NE
Adams|Adams
Antelope|Antelope
Arthur|Arthur
Banner|Banner
Blaine|Blaine
Boone|Boone
Box Butte|Box Butte
Boyd|Boyd
Brown|Brown
Buffalo|Buffalo
Burt|Burt
Butler|Butler
Cass|Cass
Cedar|Cedar
Chase|Chase
Cherry|Cherry
Cheyenne|Cheyenne
Clay|Clay
Colfax|Colfax
Cuming|Cuming
Custer|Custer
Dakota|Dakota
Dawes|Dawes
Dawson|Dawson
Deuel|Deuel
Dixon|Dixon
Dodge|Dodge
Douglas|Douglas
Dundy|Dundy
Fillmore|Fillmore
Franklin|Franklin
Frontier|Frontier
Furnas|Furnas
Gage|Gage
Garden|Garden
Garfield|Garfield
Gosper|Gosper
Grant|Grant
Greeley|Greeley
Hall|Hall
Hamilton|Hamilton
Harlan|Harlan
Hayes|Hayes
Hitchcock|Hitchcock
Holt|Holt
Hooker|Hooker
Howard|Howard
Jefferson|Jefferson
Johnson|Johnson
Kearney|Kearney
Keith|Keith
Keya Paha|Keya Paha
Kimball|Kimball
Knox|Knox
Lancaster|Lancaster
Lincoln|Lincoln
Logan|Logan
Loup|Loup
Madison|Madison
McPherson|McPherson
Merrick|Merrick
Morrill|Morrill
Nance|Nance
Nemaha|Nemaha
Nuckolls|Nuckolls
Otoe|Otoe
Pawnee|Pawnee
Perkins|Perkins
Phelps|Phelps
Pierce|Pierce
Platte|Platte
Polk|Polk
Red Willow|Red Willow
Richardson|Richardson
Rock|Rock
Saline|Saline
Sarpy|Sarpy
Saunders|Saunders
Scotts Bluff|Scotts Bluff
Seward|Seward
Sheridan|Sheridan
Sherman|Sherman
Sioux|Sioux
Stanton|Stanton
Thayer|Thayer
Thomas|Thomas
Thurston|Thurston
Valley|Valley
Washington|Washington
Wayne|Wayne
Webster|Webster
Wheeler|Wheeler
York|York
@US_COUNTY/NH
Belknap|Belknap
Carroll|Carroll
Cheshire|Cheshire
Coos|Coos
Grafton|Grafton
Hillsborough|Hillsborough
Merrimack|Merrimack
Rockingham|Rockingham
Strafford|Strafford
Sullivan|Sullivan
@US_COUNTY/NJ
Atlantic|Atlantic
Bergen|Bergen
Burlington|Burlington
Camden|Camden
Cape May|Cape May
Cumberland|Cumberland
Essex|Essex
Gloucester|Gloucester
Hudson|Hudson
Hunterdon|Hunterdon
Mercer|Mercer
Middlesex|Middlesex
Monmouth|Monmouth
Morris|Morris
Ocean|Ocean
Passaic|Passaic
Salem|Salem
Somerset|Somerset
Sussex|Sussex
Union|Union
Warren|Warren
@US_COUNTY/NM
Bernalillo|Bernalillo
Catron|Catron
Chaves|Chaves
Cibola|Cibola
Colfax|Colfax
Curry|Curry
De Baca|De Baca
Dona Ana|Doña Ana
Eddy|Eddy
Grant|Grant
Guadalupe|Guadalupe
Harding|Harding
Hidalgo|Hidalgo
Lea|Lea
Lincoln|Lincoln
Los Alamos|Los Alamos
Luna|Luna
McKinley|McKinley
Mora|Mora
Otero|Otero
Quay|Quay
Rio Arriba|Rio Arriba
Roosevelt|Roosevelt
San Juan|San Juan
San Miguel|San Miguel
Sandoval|Sandoval
Santa Fe|Santa Fe
Sierra|Sierra
Socorro|Socorro
Taos|Taos
Torrance|Torrance
Union|Union
Valencia|Valencia
@US_COUNTY/NV
Carson City|Carson City
Churchill|Churchill
Clark|Clark
Douglas|Douglas
Elko|Elko
Esmeralda|Esmeralda
Eureka|Eureka
Humboldt|Humboldt
Lander|Lander
Lincoln|Lincoln
Lyon|Lyon
Mineral|Mineral
Nye|Nye
Pershing|Pershing
Storey|Storey
Washoe|Washoe
White Pine|White Pine
@US_COUNTY/NY
Albany|Albany
Allegany|Allegany
Bronx|Bronx
Broome|Broome
Cattaraugus|Cattaraugus
Cayuga|Cayuga
Chautauqua|Chautauqua
Chemung|Chemung
Chenango|Chenango
Clinton|Clinton
Columbia|Columbia
Cortland|Cortland
Delaware|Delaware
Dutchess|Dutchess
Erie|Erie
Essex|Essex
Franklin|Franklin
Fulton|Fulton
Genesee|Genesee
Greene|Greene
Hamilton|Hamilton
Herkimer|Herkimer
Jefferson|Jefferson
Kings|Kings
Lewis|Lewis
Livingston|Livingston
Madison|Madison
Monroe|Monroe
Montgomery|Montgomery
Nassau|Nassau
New York|New York
Niagara|Niagara
Oneida|Oneida
Onondaga|Onondaga
Ontario|Ontario
Orange|Orange
Orleans|Orleans
Oswego|Oswego
Otsego|Otsego
Putnam|Putnam
Queens|Queens
Rensselaer|Rensselaer
Richmond|Richmond
Rockland|Rockland
Saint Lawrence|St. Lawrence
Saratoga|Saratoga
Schenectady|Schenectady
Schoharie|Schoharie
Schuyler|Schuyler
Seneca|Seneca
Steuben|Steuben
Suffolk|Suffolk
Sullivan|Sullivan
Tioga|Tioga
Tompkins|Tompkins
Ulster|Ulster
Warren|Warren
Washington|Washington
Wayne|Wayne
Westchester|Westchester
Wyoming|Wyoming
Yates|Yates
@US_COUNTY/OH
Adams|Adams
Allen|Allen
Ashland|Ashland
Ashtabula|Ashtabula
Athens|Athens
Auglaize|Auglaize
Belmont|Belmont
Brown|Brown
Butler|Butler
Carroll|Carroll
Champaign|Champaign
Clark|Clark
Clermont|Clermont
Clinton|Clinton
Columbiana|Columbiana
Coshocton|Coshocton
Crawford|Crawford
Cuyahoga|Cuyahoga
Darke|Darke
Defiance|Defiance
Delaware|Delaware
Erie|Erie
Fairfield|Fairfield
Fayette|Fayette
Franklin|Franklin
Fulton|Fulton
Gallia|Gallia
Geauga|Geauga
Greene|Greene
Guernsey|Guernsey
Hamilton|Hamilton
Hancock|Hancock
Hardin|Hardin
Harrison|Harrison
Henry|Henry
Highland|Highland
Hocking|Hocking
Holmes|Holmes
Huron|Huron
Jackson|Jackson
Jefferson|Jefferson
Knox|Knox
Lake|Lake
Lawrence|Lawrence
Licking|Licking
Logan|Logan
Lorain|Lorain
Lucas|Lucas
Madison|Madison
Mahoning|Mahoning
Marion|Marion
Medina|Medina
Meigs|Meigs
Mercer|Mercer
Miami|Miami
Monroe|Monroe
Montgomery|Montgomery
Morgan|Morgan
Morrow|Morrow
Muskingum|Muskingum
Noble|Noble
Ottawa|Ottawa
Paulding|Paulding
Perry|Perry
Pickaway|Pickaway
Pike|Pike
Portage|Portage
Preble|Preble
Putnam|Putnam
Richland|Richland
Ross|Ross
Sandusky|Sandusky
Scioto|Scioto
Seneca|Seneca
Shelby|Shelby
Stark|Stark
Summit|Summit
Trumbull|Trumbull
Tuscarawas|Tuscarawas
Union|Union
Van Wert|Van Wert
Vinton|Vinton
Warren|Warren
Washington|Washington
Wayne|Wayne
Williams|Williams
Wood|Wood
Wyandot|Wyandot
@US_COUNTY/OK
Adair|Adair
Alfalfa|Alfalfa
Atoka|Atoka
Beaver|Beaver
Beckham|Beckham
Blaine|Blaine
Bryan|Bryan
Caddo|Caddo
Canadian|Canadian
Carter|Carter
Cherokee|Cherokee
Choctaw|Choctaw
Cimarron|Cimarron
Cleveland|Cleveland
Coal|Coal
Comanche|Comanche
Cotton|Cotton
Craig|Craig
Creek|Creek
Custer|Custer
Delaware|Delaware
Dewey|Dewey
Ellis|Ellis
Garfield|Garfield
Garvin|Garvin
Grady|Grady
Grant|Grant
Greer|Greer
Harmon|Harmon
Harper|Harper
Haskell|Haskell
Hughes|Hughes
Jackson|Jackson
Jefferson|Jefferson
Johnston|Johnston
Kay|Kay
Kingfisher|Kingfisher
Kiowa|Kiowa
Latimer|Latimer
Le Flore|Le Flore
Lincoln|Lincoln
Logan|Logan
Love|Love
Major|Major
Marshall|Marshall
Mayes|Mayes
McClain|McClain
McCurtain|McCurtain
McIntosh|McIntosh
Murray|Murray
Muskogee|Muskogee
Noble|Noble
Nowata|Nowata
Okfuskee|Okfuskee
Oklahoma|Oklahoma
Okmulgee|Okmulgee
Osage|Osage
Ottawa|Ottawa
Pawnee|Pawnee
Payne|Payne
Pittsburg|Pittsburg
Pontotoc|Pontotoc
Pottawatomie|Pottawatomie
Pushmataha|Pushmataha
Roger Mills|Roger Mills
Rogers|Rogers
Seminole|Seminole
Sequoyah|Sequoyah
Stephens|Stephens
Texas|Texas
Tillman|Tillman
Tulsa|Tulsa
Wagoner|Wagoner
Washington|Washington
Washita|Washita
Woods|Woods
Woodward|Woodward
@US_COUNTY/OR
Baker|Baker
Benton|Benton
Clackamas|Clackamas
Clatsop|Clatsop
Columbia|Columbia
Coos|Coos
Crook|Crook
Curry|Curry
Deschutes|Deschutes
Douglas|Douglas
Gilliam|Gilliam
Grant|Grant
Harney|Harney
Hood River|Hood River
Jackson|Jackson
Jefferson|Jefferson
Josephine|Josephine
Klamath|Klamath
Lake|Lake
Lane|Lane
Lincoln|Lincoln
Linn|Linn
Malheur|Malheur
Marion|Marion
Morrow|Morrow
Multnomah|Multnomah
Polk|Polk
Sherman|Sherman
Tillamook|Tillamook
Umatilla|Umatilla
Union|Union
Wallowa|Wallowa
Wasco|Wasco
Washington|Washington
Wheeler|Wheeler
Yamhill|Yamhill
@US_COUNTY/PA
Adams|Adams
Allegheny|Allegheny
Armstrong|Armstrong
Beaver|Beaver
Bedford|Bedford
Berks|Berks
Blair|Blair
Bradford|Bradford
Bucks|Bucks
Butler|Butler
Cambria|Cambria
Cameron|Cameron
Carbon|Carbon
Center|Center
Chester|Chester
Clarion|Clarion
Clearfield|Clearfield
Clinton|Clinton
Columbia|Columbia
Crawford|Crawford
Cumberland|Cumberland
Dauphin|Dauphin
Delaware|Delaware
Elk|Elk
Erie|Erie
Fayette|Fayette
Forest|Forest
Franklin|Franklin
Fulton|Fulton
Greene|Greene
Huntingdon|Huntingdon
Indiana|Indiana
Jefferson|Jefferson
Juniata|Juniata
Lackawanna|Lackawanna
Lancaster|Lancaster
Lawrence|Lawrence
Lebanon|Lebanon
Lehigh|Lehigh
Luzerne|Luzerne
Lycoming|Lycoming
McKean|McKean
Mercer|Mercer
Mifflin|Mifflin
Monroe|Monroe
Montgomery|Montgomery
Montour|Montour
Northampton|Northampton
Northumberland|Northumberland
Perry|Perry
Philadelphia|Philadelphia
Pike|Pike
Potter|Potter
Schuylkill|Schuylkill
Snyder|Snyder
Somerset|Somerset
Sullivan|Sullivan
Susquehanna|Susquehanna
Tioga|Tioga
Union|Union
Venango|Venango
Warren|Warren
Washington|Washington
Wayne|Wayne
Westmoreland|Westmoreland
Wyoming|Wyoming
York|York
@US_COUNTY/RI
Bristol|Bristol
Kent|Kent
Newport|Newport
Providence|Providence
Washington|Washington
@US_COUNTY/SC
Abbeville|Abbeville
Aiken|Aiken
Allendale|Allendale
Anderson|Anderson
Bamberg|Bamberg
Barnwell|Barnwell
Beaufort|Beaufort
Berkeley|Berkeley
Calhoun|Calhoun
Charleston|Charleston
Cherokee|Cherokee
Chester|Chester
Chesterfield|Chesterfield
Clarendon|Clarendon
Colleton|Colleton
Darlington|Darlington
Dillon|Dillon
Dorchester|Dorchester
Edgefield|Edgefield
Fairfield|Fairfield
Florence|Florence
Georgetown|Georgetown
Greenville|Greenville
Greenwood|Greenwood
Hampton|Hampton
Horry|Horry
Jasper|Jasper
Kershaw|Kershaw
Lancaster|Lancaster
Laurens|Laurens
Lee|Lee
Lexington|Lexington
Marion|Marion
Marlboro|Marlboro
McCormick|McCormick
Newberry|Newberry
Oconee|Oconee
Orangeburg|Orangeburg
Pickens|Pickens
Richland|Richland
Saluda|Saluda
Spartanburg|Spartanburg
Sumter|Sumter
Union|Union
Williamsburg|Williamsburg
York|York
@US_COUNTY/SD
Aurora|Aurora
Beadle|Beadle
Bennett|Bennett
Bon Homme|Bon Homme
Brookings|Brookings
Brown|Brown
Brule|Brule
Buffalo|Buffalo
Butte|Butte
Campbell|Campbell
Charles Mix|Charles Mix
Clark|Clark
Clay|Clay
Codington|Codington
Corson|Corson
Custer|Custer
Davison|Davison
Day|Day
Deuel|Deuel
Dewey|Dewey
Douglas|Douglas
Edmunds|Edmunds
Fall River|Fall River
Faulk|Faulk
Grant|Grant
Gregory|Gregory
Haakon|Haakon
Hamlin|Hamlin
Hand|Hand
Hanson|Hanson
Harding|Harding
Hughes|Hughes
Hutchinson|Hutchinson
Hyde|Hyde
Jackson|Jackson
Jerauld|Jerauld
Jones|Jones
Kingsbury|Kingsbury
Lake|Lake
Lawrence|Lawrence
Lincoln|Lincoln
Lyman|Lyman
Marshall|Marshall
McCook|McCook
McPherson|McPherson
Meade|Meade
Mellette|Mellette
Miner|Miner
Minnehaha|Minnehaha
Moody|Moody
Oglala Lakota|Oglala Lakota
Pennington|Pennington
Perkins|Perkins
Potter|Potter
Roberts|Roberts
Sanborn|Sanborn
Shannon|Shannon
Spink|Spink
Stanley|Stanley
Sully|Sully
Todd|Todd
Tripp|Tripp
Turner|Turner
Union|Union
Walworth|Walworth
Yankton|Yankton
Ziebach|Ziebach
@US_COUNTY/TN
Anderson|Anderson
Bedford|Bedford
Benton|Benton
Bledsoe|Bledsoe
Blount|Blount
Bradley|Bradley
Campbell|Campbell
Cannon|Cannon
Carroll|Carroll
Carter|Carter
Cheatham|Cheatham
Chester|Chester
Claiborne|Claiborne
Clay|Clay
Cocke|Cocke
Coffee|Coffee
Crockett|Crockett
Cumberland|Cumberland
Davidson|Davidson
Decatur|Decatur
Dekalb|DeKalb
Dickson|Dickson
Dyer|Dyer
Fayette|Fayette
Fentress|Fentress
Franklin|Franklin
Gibson|Gibson
Giles|Giles
Grainger|Grainger
Greene|Greene
Grundy|Grundy
Hamblen|Hamblen
Hamilton|Hamilton
Hancock|Hancock
Hardeman|Hardeman
Hardin|Hardin
Hawkins|Hawkins
Haywood|Haywood
Henderson|Henderson
Henry|Henry
Hickman|Hickman
Houston|Houston
Humphreys|Humphreys
Jackson|Jackson
Jefferson|Jefferson
Johnson|Johnson
Knox|Knox
Lake|Lake
Lauderdale|Lauderdale
Lawrence|Lawrence
Lewis|Lewis
Lincoln|Lincoln
Loudon|Loudon
Macon|Macon
Madison|Madison
Marion|Marion
Marshall|Marshall
Maury|Maury
McMinn|McMinn
McNairy|McNairy
Meigs|Meigs
Monroe|Monroe
Montgomery|Montgomery
Moore|Moore
Morgan|Morgan
Obion|Obion
Overton|Overton
Perry|Perry
Pickett|Pickett
Polk|Polk
Putnam|Putnam
Rhea|Rhea
Roane|Roane
Robertson|Robertson
Rutherford|Rutherford
Scott|Scott
Sequatchie|Sequatchie
Sevier|Sevier
Shelby|Shelby
Smith|Smith
Stewart|Stewart
Sullivan|Sullivan
Sumner|Sumner
Tipton|Tipton
Trousdale|Trousdale
Unicoi|Unicoi
Union|Union
Van Buren|Van Buren
Warren|Warren
Washington|Washington
Wayne|Wayne
Weakley|Weakley
White|White
Williamson|Williamson
Wilson|Wilson
@US_COUNTY/TX
Anderson|Anderson
Andrews|Andrews
Angelina|Angelina
Aransas|Aransas
Archer|Archer
Armstrong|Armstrong
Atascosa|Atascosa
Austin|Austin
Bailey|Bailey
Bandera|Bandera
Bastrop|Bastrop
Baylor|Baylor
Bee|Bee
Bell|Bell
Bexar|Bexar
Blanco|Blanco
Borden|Borden
Bosque|Bosque
Bowie|Bowie
Brazoria|Brazoria
Brazos|Brazos
Brewster|Brewster
Briscoe|Briscoe
Brooks|Brooks
Brown|Brown
Burleson|Burleson
Burnet|Burnet
Caldwell|Caldwell
Calhoun|Calhoun
Callahan|Callahan
Cameron|Cameron
Camp|Camp
Carson|Carson
Cass|Cass
Castro|Castro
Chambers|Chambers
Cherokee|Cherokee
Childress|Childress
Clay|Clay
Cochran|Cochran
Coke|Coke
Coleman|Coleman
Collin|Collin
Collingsworth|Collingsworth
Colorado|Colorado
Comal|Comal
Comanche|Comanche
Concho|Concho
Cooke|Cooke
Coryell|Coryell
Cottle|Cottle
Crane|Crane
Crockett|Crockett
Crosby|Crosby
Culberson|Culberson
Dallam|Dallam
Dallas|Dallas
Dawson|Dawson
De Witt|DeWitt
Deaf Smith|Deaf Smith
Delta|Delta
Denton|Denton
Dickens|Dickens
Dimmit|Dimmit
Donley|Donley
Duval|Duval
Eastland|Eastland
Ector|Ector
Edwards|Edwards
El Paso|El Paso
Ellis|Ellis
Erath|Erath
Falls|Falls
Fannin|Fannin
Fayette|Fayette
Fisher|Fisher
Floyd|Floyd
Foard|Foard
Fort Bend|Fort Bend
Franklin|Franklin
Freestone|Freestone
Frio|Frio
Gaines|Gaines
Galveston|Galveston
Garza|Garza
Gillespie|Gillespie
Glasscock|Glasscock
Goliad|Goliad
Gonzales|Gonzales
Gray|Gray
Grayson|Grayson
Gregg|Gregg
Grimes|Grimes
Guadalupe|Guadalupe
Hale|Hale
Hall|Hall
Hamilton|Hamilton
Hansford|Hansford
Hardeman|Hardeman
Hardin|Hardin
Harris|Harris
Harrison|Harrison
Hartley|Hartley
Haskell|Haskell
Hays|Hays
Hemphill|Hemphill
Henderson|Henderson
Hidalgo|Hidalgo
Hill|Hill
Hockley|Hockley
Hood|Hood
Hopkins|Hopkins
Houston|Houston
Howard|Howard
Hudspeth|Hudspeth
Hunt|Hunt
Hutchinson|Hutchinson
Irion|Irion
Jack|Jack
Jackson|Jackson
Jasper|Jasper
Jeff Davis|Jeff Davis
Jefferson|Jefferson
Jim Hogg|Jim Hogg
Jim Wells|Jim Wells
Johnson|Johnson
Jones|Jones
Karnes|Karnes
Kaufman|Kaufman
Kendall|Kendall
Kenedy|Kenedy
Kent|Kent
Kerr|Kerr
Kimble|Kimble
King|King
Kinney|Kinney
Kleberg|Kleberg
Knox|Knox
La Salle|La Salle
Lamar|Lamar
Lamb|Lamb
Lampasas|Lampasas
Lavaca|Lavaca
Lee|Lee
Leon|Leon
Liberty|Liberty
Limestone|Limestone
Lipscomb|Lipscomb
Live Oak|Live Oak
Llano|Llano
Loving|Loving
Lubbock|Lubbock
Lynn|Lynn
Madison|Madison
Marion|Marion
Martin|Martin
Mason|Mason
Matagorda|Matagorda
Maverick|Maverick
McCulloch|McCulloch
McLennan|McLennan
McMullen|McMullen
Medina|Medina
Menard|Menard
Midland|Midland
Milam|Milam
Mills|Mills
Mitchell|Mitchell
Montague|Montague
Montgomery|Montgomery
Moore|Moore
Morris|Morris
Motley|Motley
Nacogdoches|Nacogdoches
Navarro|Navarro
Newton|Newton
Nolan|Nolan
Nueces|Nueces
Ochiltree|Ochiltree
Oldham|Oldham
Orange|Orange
Palo Pinto|Palo Pinto
Panola|Panola
Parker|Parker
Parmer|Parmer
Pecos|Pecos
Polk|Polk
Potter|Potter
Presidio|Presidio
Rains|Rains
Randall|Randall
Reagan|Reagan
Real|Real
Red River|Red River
Reeves|Reeves
Refugio|Refugio
Roberts|Roberts
Robertson|Robertson
Rockwall|Rockwall
Runnels|Runnels
Rusk|Rusk
Sabine|Sabine
San Augustine|San Augustine
San Jacinto|San Jacinto
San Patricio|San Patricio
San Saba|San Saba
Schleicher|Schleicher
Scurry|Scurry
Shackelford|Shackelford
Shelby|Shelby
Sherman|Sherman
Smith|Smith
Somervell|Somervell
Starr|Starr
Stephens|Stephens
Sterling|Sterling
Stonewall|Stonewall
Sutton|Sutton
Swisher|Swisher
Tarrant|Tarrant
Taylor|Taylor
Terrell|Terrell
Terry|Terry
Throckmorton|Throckmorton
Titus|Titus
Tom Green|Tom Green
Travis|Travis
Trinity|Trinity
Tyler|Tyler
Upshur|Upshur
Upton|Upton
Uvalde|Uvalde
Val Verde|Val Verde
Van Zandt|Van Zandt
Victoria|Victoria
Walker|Walker
Waller|Waller
Ward|Ward
Washington|Washington
Webb|Webb
Wharton|Wharton
Wheeler|Wheeler
Wichita|Wichita
Wilbarger|Wilbarger
Willacy|Willacy
Williamson|Williamson
Wilson|Wilson
Winkler|Winkler
Wise|Wise
Wood|Wood
Yoakum|Yoakum
Young|Young
Zapata|Zapata
Zavala|Zavala
@US_COUNTY/UT
Beaver|Beaver
Box Elder|Box Elder
Cache|Cache
Carbon|Carbon
Daggett|Daggett
Davis|Davis
Duchesne|Duchesne
Emery|Emery
Garfield|Garfield
Grand|Grand
Iron|Iron
Juab|Juab
Kane|Kane
Millard|Millard
Morgan|Morgan
Piute|Piute
Rich|Rich
Salt Lake|Salt Lake
San Juan|San Juan
Sanpete|Sanpete
Sevier|Sevier
Summit|Summit
Tooele|Tooele
Uintah|Uintah
Utah|Utah
Wasatch|Wasatch
Washington|Washington
Wayne|Wayne
Weber|Weber
@US_COUNTY/VA
Accomack|Accomack
Albemarle|Albemarle
Alexandria City|Alexandria City
Alleghany|Alleghany
Amelia|Amelia
Amherst|Amherst
Appomattox|Appomattox
Arlington|Arlington
Augusta|Augusta
Bath|Bath
Bedford|Bedford
Bedford City|Bedford City
Bland|Bland
Botetourt|Botetourt
Bristol|Bristol City
Brunswick|Brunswick
Buchanan|Buchanan
Buckingham|Buckingham
Buena Vista City|Buena Vista City
Campbell|Campbell
Caroline|Caroline
Carroll|Carroll
Charles City|Charles City
Charlotte|Charlotte
Charlottesville City|Charlottesville City
Chesapeake City|Chesapeake City
Chesterfield|Chesterfield
Clarke|Clarke
Clifton Forge City|Clifton Forge City
Colonial Heights City|Colonial Heights City
Covington City|Covington City
Craig|Craig
Culpeper|Culpeper
Cumberland|Cumberland
Danville City|Danville City
Dickenson|Dickenson
Dinwiddie|Dinwiddie
Emporia City|Emporia City
Essex|Essex
Fairfax|Fairfax
Fairfax City|Fairfax City
Falls Church City|Falls Church City
Fauquier|Fauquier
Floyd|Floyd
Fluvanna|Fluvanna
Franklin|Franklin
Franklin City|Franklin City
Frederick|Frederick
Fredericksburg City|Fredericksburg City
Galax City|Galax City
Giles|Giles
Gloucester|Gloucester
Goochland|Goochland
Grayson|Grayson
Greene|Greene
Greensville|Greensville
Halifax|Halifax
Hampton City|Hampton City
Hanover|Hanover
Harrisonburg City|Harrisonburg City
Henrico|Henrico
Henry|Henry
Highland|Highland
Hopewell City|Hopewell City
Isle of Wight|Isle of Wight
James City|James City
King and Queen|King and Queen
King George|King George
King William|King William
Lancaster|Lancaster
Lee|Lee
Lexington City|Lexington City
Loudoun|Loudoun
Louisa|Louisa
Lunenburg|Lunenburg
Lynchburg City|Lynchburg City
Madison|Madison
Manassas City|Manassas City
Manassas Park City|Manassas Park City
Martinsville City|Martinsville City
Mathews|Mathews
Mecklenburg|Mecklenburg
Middlesex|Middlesex
Montgomery|Montgomery
Nelson|Nelson
New Kent|New Kent
Newport News City|Newport News City
Norfolk City|Norfolk City
Northampton|Northampton
Northumberland|Northumberland
Norton City|Norton City
Nottoway|Nottoway
Orange|Orange
Page|Page
Patrick|Patrick
Petersburg City|Petersburg City
Pittsylvania|Pittsylvania
Poquoson City|Poquoson City
Portsmouth City|Portsmouth City
Powhatan|Powhatan
Prince Edward|Prince Edward
Prince George|Prince George
Prince William|Prince William
Pulaski|Pulaski
Radford City|Radford City
Rappahannock|Rappahannock
Richmond|Richmond
Richmond City|Richmond City
Roanoke|Roanoke
Roanoke City|Roanoke City
Rockbridge|Rockbridge
Rockingham|Rockingham
Russell|Russell
Salem|Salem City
Scott|Scott
Shenandoah|Shenandoah
Smyth|Smyth
Southampton|Southampton
Spotsylvania|Spotsylvania
Stafford|Stafford
Staunton City|Staunton City
Suffolk City|Suffolk City
Surry|Surry
Sussex|Sussex
Tazewell|Tazewell
Virginia Beach City|Virginia Beach City
Warren|Warren
Washington|Washington
Waynesboro City|Waynesboro City
Westmoreland|Westmoreland
Williamsburg City|Williamsburg City
Winchester City|Winchester City
Wise|Wise
Wythe|Wythe
York|York
@US_COUNTY/VT
Addison|Addison
Bennington|Bennington
Caledonia|Caledonia
Chittenden|Chittenden
Essex|Essex
Franklin|Franklin
Grand Isle|Grand Isle
Lamoille|Lamoille
Orange|Orange
Orleans|Orleans
Rutland|Rutland
Washington|Washington
Windham|Windham
Windsor|Windsor
@US_COUNTY/WA
Adams|Adams
Asotin|Asotin
Benton|Benton
Chelan|Chelan
Clallam|Clallam
Clark|Clark
Columbia|Columbia
Cowlitz|Cowlitz
Douglas|Douglas
Ferry|Ferry
Franklin|Franklin
Garfield|Garfield
Grant|Grant
Grays Harbor|Grays Harbor
Island|Island
Jefferson|Jefferson
King|King
Kitsap|Kitsap
Kittitas|Kittitas
Klickitat|Klickitat
Lewis|Lewis
Lincoln|Lincoln
Mason|Mason
Okanogan|Okanogan
Pacific|Pacific
Pend Oreille|Pend Oreille
Pierce|Pierce
San Juan|San Juan
Skagit|Skagit
Skamania|Skamania
Snohomish|Snohomish
Spokane|Spokane
Stevens|Stevens
Thurston|Thurston
Wahkiakum|Wahkiakum
Walla Walla|Walla Walla
Whatcom|Whatcom
Whitman|Whitman
Yakima|Yakima
@US_COUNTY/WI
Adams|Adams
Ashland|Ashland
Barron|Barron
Bayfield|Bayfield
Brown|Brown
Buffalo|Buffalo
Burnett|Burnett
Calumet|Calumet
Chippewa|Chippewa
Clark|Clark
Columbia|Columbia
Crawford|Crawford
Dane|Dane
Dodge|Dodge
Door|Door
Douglas|Douglas
Dunn|Dunn
Eau Claire|Eau Claire
Florence|Florence
Fond du Lac|Fond du Lac
Forest|Forest
Grant|Grant
Green|Green
Green Lake|Green Lake
Iowa|Iowa
Iron|Iron
Jackson|Jackson
Jefferson|Jefferson
Juneau|Juneau
Kenosha|Kenosha
Kewaunee|Kewaunee
La Crosse|La Crosse
Lafayette|Lafayette
Langlade|Langlade
Lincoln|Lincoln
Manitowoc|Manitowoc
Marathon|Marathon
Marinette|Marinette
Marquette|Marquette
Menominee|Menominee
Milwaukee|Milwaukee
Monroe|Monroe
Oconto|Oconto
Oneida|Oneida
Outagamie|Outagamie
Ozaukee|Ozaukee
Pepin|Pepin
Pierce|Pierce
Polk|Polk
Portage|Portage
Price|Price
Racine|Racine
Richland|Richland
Rock|Rock
Rusk|Rusk
Saint Croix|St. Croix
Sauk|Sauk
Sawyer|Sawyer
Shawano|Shawano
Sheboygan|Sheboygan
Taylor|Taylor
Trempealeau|Trempealeau
Vernon|Vernon
Vilas|Vilas
Walworth|Walworth
Washburn|Washburn
Washington|Washington
Waukesha|Waukesha
Waupaca|Waupaca
Waushara|Waushara
Winnebago|Winnebago
Wood|Wood
@US_COUNTY/WV
Barbour|Barbour
Berkeley|Berkeley
Boone|Boone
Braxton|Braxton
Brooke|Brooke
Cabell|Cabell
Calhoun|Calhoun
Clay|Clay
Doddridge|Doddridge
Fayette|Fayette
Gilmer|Gilmer
Grant|Grant
Greenbrier|Greenbrier
Hampshire|Hampshire
Hancock|Hancock
Hardy|Hardy
Harrison|Harrison
Jackson|Jackson
Jefferson|Jefferson
Kanawha|Kanawha
Lewis|Lewis
Lincoln|Lincoln
Logan|Logan
Marion|Marion
Marshall|Marshall
Mason|Mason
McDowell|McDowell
Mercer|Mercer
Mineral|Mineral
Mingo|Mingo
Monongalia|Monongalia
Monroe|Monroe
Morgan|Morgan
Nicholas|Nicholas
Ohio|Ohio
Pendleton|Pendleton
Pleasants|Pleasants
Pocahontas|Pocahontas
Preston|Preston
Putnam|Putnam
Raleigh|Raleigh
Randolph|Randolph
Ritchie|Ritchie
Roane|Roane
Summers|Summers
Taylor|Taylor
Tucker|Tucker
Tyler|Tyler
Upshur|Upshur
Wayne|Wayne
Webster|Webster
Wetzel|Wetzel
Wirt|Wirt
Wood|Wood
Wyoming|Wyoming
@US_COUNTY/WY
Albany|Albany
Big Horn|Big Horn
Campbell|Campbell
Carbon|Carbon
Converse|Converse
Crook|Crook
Fremont|Fremont
Goshen|Goshen
Hot Springs|Hot Springs
Johnson|Johnson
Laramie|Laramie
Lincoln|Lincoln
Natrona|Natrona
Niobrara|Niobrara
Park|Park
Platte|Platte
Sheridan|Sheridan
Sublette|Sublette
Sweetwater|Sweetwater
Teton|Teton
Uinta|Uinta
Washakie|Washakie
Weston|Weston
@JA_CITY_GUN_KU/01
0101|Sapporo-shi
0102|Asahikawa-shi
0103|Otaru-shi
0104|Hakodate-shi
0105|Muroran-shi
0106|Kushiro-shi
0107|Obihiro-shi
0108|Kitami-shi
0109|Yubari-shi
0110|Iwamizawa-shi
0111|Abashiri-shi
0112|Rumoi-shi
0113|Tomakomai-shi
0114|Wakkanai-shi
0115|Bibai-shi
0116|Ashibetsu-shi
0117|Ebetsu-shi
0118|Akabira-shi
0119|Mombetsu-shi
0120|Shibetsu-shi
0121|Nayoro-shi
0122|Mikasa-shi
0123|Nemuro-shi
0124|Chitose-shi
0125|Takikawa-shi
0126|Sunagawa-shi
0127|Utashinai-shi
0128|Fukagawa-shi
0129|Furano-shi
0130|Noboribetsu-shi
0131|Eniwa-shi
0132|Kameda-shi
0133|Date-shi
0134|Kitahiroshima-shi
0135|Ishikari-shi
0136|Hokuto-shi
01001|Akan-gun
01002|Ashoro-gun
01003|Atsukeshi-gun
01004|Atsuta-gun
01005|Abashiri-gun
01006|Abuta-gun (Shiribeshi)
01007|Abuta-gun (Iburi)
01008|Ishikari-gun
01009|Isoya-gun
01010|Iwanai-gun
01011|Usu-gun
01012|Utasutsu-gun
01013|Urakawa-gun
01014|Uryu-gun (Sorachi)
01015|Esashi-gun
01016|Okushiri-gun
01017|Oshoro-gun
01018|Kasai-gun
01019|Kato-gun
01020|Kabato-gun
01021|Kamiiso-gun
01022|Kamikawa-gun (Tokachi)
01023|Kamikawa-gun (Kamikawa)
01024|Kameda-gun
01025|Kayabe-gun
01026|Kawakami-gun
01027|Kushiro-gun
01028|Kudo-gun
01029|Sapporo-gun
01030|Samani-gun
01031|Saru-gun
01032|Shizunai-gun
01033|Shibetsu-gun
01034|Shimamaki-gun
01035|Shakotan-gun
01036|Shari-gun
01037|Shiraoi-gun
01038|Shiranuka-gun
01039|Suttsu-gun
01040|Setana-gun
01041|Soya-gun
01042|Sorachi-gun (Sorachi)
01043|Sorachi-gun (Kamikawa)
01044|Chitose-gun
01045|Teshio-gun (Rumoi)
01046|Teshio-gun (Soya)
01047|Tokachi-gun
01048|Tokoro-gun
01049|Tomamae-gun
01050|Nakagawa-gun (Kamikawa)
01051|Nakagawa-gun (Tokachi)
01052|Niikappu-gun
01053|Nishi-gun
01054|Nemuro-gun
01055|Notsuke-gun
01056|Hanasaki-gun
01057|Hamamasu-gun
01058|Bikuni-gun
01059|Hiyama-gun
01060|Hiroo-gun
01061|Futoro-gun
01062|Furuu-gun
01063|Furubira-gun
01064|Horoizumi-gun
01065|Horobetsu-gun
01066|Mashike-gun
01067|Matsumae-gun
01068|Mitsuishi-gun
01069|Menashi-gun
01070|Mombetsu-gun
01071|Yamakoshi-gun
01072|Yubari-gun
01073|Yufutsu-gun (Iburi)
01074|Yufutsu-gun (Kamikawa)
01075|Yoichi-gun
01076|Rishiri-gun
01077|Rumoi-gun
01078|Rebun-gun
01079|Futami-gun
01080|Hidaka-gun
01081|Uryu-gun (Kamikawa)
010101|Chuo-ku
010102|Kita-ku
010103|Higashi-ku
010104|Shiroishi-ku
010105|Toyohira-ku
010106|Minami-ku
010107|Nishi-ku
010108|Atsubetsu-ku
010109|Teine-ku
010110|Kiyota-ku
@JA_CITY_GUN_KU/02
0201|Aomori-shi
0202|Hirosaki-shi
0203|Hachinohe-shi
0204|Kuroishi-shi
0205|Goshogawara-shi
0206|Towada-shi
0207|Misawa-shi
0208|Mutsu-shi
0209|Tsugaru-shi
0210|Hirakawa-shi
02001|Kamikita-gun
02002|Kitatsugaru-gun
02003|Sannohe-gun
02004|Shimokita-gun
02005|Nakatsugaru-gun
02006|Nishitsugaru-gun
02007|Higashitsugaru-gun
02008|Minamitsugaru-gun
@JA_CITY_GUN_KU/03
0301|Morioka-shi
0302|Kamaishi-shi
0303|Miyako-shi
0304|Ichinoseki-shi
0305|Ofunato-shi
0306|Mizusawa-shi
0307|Hanamaki-shi
0308|Kitakami-shi
0309|Kuji-shi
0310|Tono-shi
0311|Rikuzentakata-shi
0312|Esashi-shi
0313|Ninohe-shi
0314|Hachimantai-shi
0315|Oshu-shi
0316|Takizawa-shi
03001|Isawa-gun
03002|Iwate-gun
03003|Esashi-gun
03004|Kamihei-gun
03005|Kunohe-gun
03006|Kesen-gun
03007|Shimohei-gun
03008|Shiwa-gun
03009|Nishiiwai-gun
03010|Ninohe-gun
03011|Hienuki-gun
03012|Higashiiwai-gun
03013|Waga-gun
@JA_CITY_GUN_KU/04
0401|Akita-shi
0402|Noshiro-shi
0403|Odate-shi
0404|Yokote-shi
0405|Honjo-shi
0406|Oga-shi
0407|Yuzawa-shi
0408|Omagari-shi
0409|Kazuno-shi
0410|Yurihonjo-shi
0411|Katagami-shi
0412|Daisen-shi
0413|Kitaakita-shi
0414|Nikaho-shi
0415|Senboku-shi
04001|Ogachi-gun
04002|Kaduno-gun
04003|Kawabe-gun
04004|Kitaakita-gun
04005|Semboku-gun
04006|Hiraka-gun
04007|Minamiakita-gun
04008|Yamamoto-gun
04009|Yuri-gun
@JA_CITY_GUN_KU/05
0501|Yamagata-shi
0502|Yonezawa-shi
0503|Tsuruoka-shi
0504|Sakata-shi
0505|Shinjo-shi
0506|Sagae-shi
0507|Kaminoyama-shi
0508|Murayama-shi
0509|Nagai-shi
0510|Tendo-shi
0511|Higashine-shi
0512|Obanazawa-shi
0513|Nan01yo-shi
05001|Akumi-gun
05002|Kitamurayama-gun
05003|Nishiokitama-gun
05004|Nishitagawa-gun
05005|Nishimurayama-gun
05006|Higashiokitama-gun
05007|Higashitagawa-gun
05008|Higashimurayama-gun
05009|Minamiokitama-gun
05010|Minamimurayama-gun
05011|Mogami-gun
@JA_CITY_GUN_KU/06
0601|Sendai-shi
0602|Ishinomaki-shi
0603|Shiogama-shi
0604|Furukawa-shi
0605|Kesennuma-shi
0606|Shiroishi-shi
0607|Natori-shi
0608|Kakuda-shi
0609|Tagajo-shi
0610|Izumi-shi
0611|Iwanuma-shi
0612|Tome-shi
0613|Kuruhara-shi
0614|Higashimatsushima-shi
0615|Osaki-shi
0616|Tomiya-shi
06001|Igu-gun
06002|Oshika-gun
06003|Katta-gun
06004|Kami-gun
06005|Kurihara-gun
06006|Kurokawa-gun
06007|Shida-gun
06008|Shibata-gun
06009|Tamadukuri-gun
06010|Toda-gun
06011|Tome-gun
06012|Natori-gun
06013|Miyagi-gun
06014|Motoyoshi-gun
06015|Monou-gun
06016|Watari-gun
060101|Aoba-ku
060102|Miyagino-ku
060103|Wakabayashi-ku
060104|Taihaku-ku
060105|Izumi-ku
@JA_CITY_GUN_KU/07
0701|Fukushima-shi
0702|Aizuwakamatsu-shi
0703|Koriyama-shi
0704|Taira-shi
0705|Shirakawa-shi
0706|Haramachi-shi
0707|Sukagawa-shi
0708|Kitakata-shi
0709|Joban-shi
0710|Iwaki-shi
0711|Soma-shi
0712|Uchigo-shi
0713|Nakoso-shi
0714|Nihonmatsu-shi
0715|Iwaki-shi
0716|Wakamatsu-shi
0717|Tamura-shi
0718|Minamisoma-shi
0719|Date-shi
0720|Motomiya-shi
07001|Asaka-gun
07002|Adachi-gun
07003|Ishikawa-gun
07004|Ishiki-gun
07005|Iwase-gun
07006|Onuma-gun
07007|Kawanuma-gun
07008|Kitaaidu-gun
07009|Shinobu-gun
07010|Soma-gun
07011|Date-gun
07012|Tamura-gun
07013|Nishishirakawa-gun
07014|Higashishirakawa-gun
07015|Futaba-gun
07016|Minamiaidu-gun
07017|Yama-gun
@JA_CITY_GUN_KU/08
0801|Niigata-shi
0802|Nagaoka-shi
0803|Takada-shi
0804|Sanjo-shi
0805|Kashiwazaki-shi
0806|Shibata-shi
0807|Niitsu-shi
0808|Ojiya-shi
0809|Kamo-shi
0810|Tokamachi-shi
0811|Mitsuke-shi
0812|Murakami-shi
0813|Tsubame-shi
0814|Naoetsu-shi
0815|Tochio-shi
0816|Itoigawa-shi
0817|Arai-shi
0818|Gosen-shi
0819|Ryotsu-shi
0820|Shirone-shi
0821|Toyosaka-shi
0822|Joetsu-shi
0823|Agano-shi
0824|Sado-shi
0825|Uonuma-shi
0826|Minamiuonuma-shi
0827|Myoko-shi
0828|Tainai-shi
08001|Iwafune-gun
08002|Kariwa-gun
08003|Kitauonuma-gun
08004|Kitakambara-gun
08005|Koshi-gun
08006|Sado-gun
08007|Santo-gun
08008|Nakauonuma-gun
08009|Nakakambara-gun
08010|Nakakubiki-gun
08011|Nishikambara-gun
08012|Nishikubiki-gun
08013|Higashikambara-gun
08014|Higashikubiki-gun
08015|Minamiuonuma-gun
08016|Minamikambara-gun
080101|Kita-ku
080102|Higashi-ku
080103|Chuo-ku
080104|Konan-ku
080105|Akiha-ku
080106|Minami-ku
080107|Nishi-ku
080108|Nishikan-ku
@JA_CITY_GUN_KU/09
0901|Nagano-shi
0902|Matsumoto-shi
0903|Ueda-shi
0904|Okaya-shi
0905|Iida-shi
0906|Suwa-shi
0907|Suzaka-shi
0908|Komoro-shi
0909|Ina-shi
0910|Komagane-shi
0911|Nakano-shi
0912|Omachi-shi
0913|Iiyama-shi
0914|Chino-shi
0915|Shiojiri-shi
0916|Shinonoi-shi
0917|Koshoku-shi
0918|Saku-shi
0919|Chikuma-shi
0920|Tomi-shi
0921|Azumino-shi
09001|Kamiina-gun
09002|Kamitakai-gun
09003|Kamiminochi-gun
09004|Kiso-gun
09005|Kitaazumi-gun
09006|Kitasaku-gun
09007|Sarashina-gun
09008|Shimoina-gun
09009|Shimotakai-gun
09010|Shimominochi-gun
09011|Suwa-gun
09012|Chiisagata-gun
09014|Hanishina-gun
09015|Higashichikuma-gun
09016|Minamiazumi-gun
09017|Minamisaku-gun
@JA_CITY_GUN_KU/10
100101|Chiyoda-ku
100102|Chuo-ku
100103|Minato-ku
100104|Shinjuku-ku
100105|Bunkyo-ku
100106|Taito-ku
100107|Sumida-ku
100108|Koto-ku
100109|Shinagawa-ku
100110|Meguro-ku
100111|Ota-ku
100112|Setagaya-ku
100113|Shibuya-ku
100114|Nakano-ku
100115|Suginami-ku
100116|Toshima-ku
100117|Kita-ku
100118|Arakawa-ku
100119|Itabashi-ku
100120|Nerima-ku
100121|Adachi-ku
100122|Katsushika-ku
100123|Edogawa-ku
1001|Tokyo 23-wards
1002|Hachioji-shi
1003|Tachikawa-shi
1004|Musashino-shi
1005|Mitaka-shi
1006|Ome-shi
1007|Fuchu-shi
1008|Akishima-shi
1009|Chofu-shi
1010|Machida-shi
1011|Koganei-shi
1012|Kodaira-shi
1013|Hino-shi
1014|Higashimurayama-shi
1015|Kokubunji-shi
1016|Kunitachi-shi
1017|Hoya-shi
1018|Tanashi-shi
1019|Fussa-shi
1020|Komae-shi
1021|Higashiyamato-shi
1022|Kiyose-shi
1023|Higashikurume-shi
1024|Musashimurayama-shi
1025|Tama-shi
1026|Inagi-shi
1027|Akigawa-shi
1028|Hamura-shi
1029|Akiruno-shi
1030|Nishitokyo-shi
10001|Kitatama-gun
10002|Nishitama-gun
10003|Minamitama-gun
10004|Oshima-gun
10005|Miyake-gun
10006|Hachijo-gun
10007|Ogawasara-gun
@JA_CITY_GUN_KU/11
1101|Yokohama-shi
1102|Yokosuka-shi
1103|Kawasaki-shi
1104|Hiratsuka-shi
1105|Kamakura-shi
1106|Fujisawa-shi
1107|Odawara-shi
1108|Chigasaki-shi
1109|Zushi-shi
1110|Sagamihara-shi
1111|Miura-shi
1112|Hadano-shi
1113|Atsugi-shi
1114|Yamato-shi
1115|Isehara-shi
1116|Ebina-shi
1117|Zama-shi
1118|Minamiashigara-shi
1119|Ayase-shi
11001|Aiko-gun
11002|Ahigarakami-gun
11003|Ashigarashimo-gun
11004|Koza-gun
11005|Tsukui-gun
11006|Naka-gun
11007|Miura-gun
110101|Tsurumi-ku
110102|Kanagawa-ku
110103|Nishi-ku
110104|Naka-ku
110105|Minami-ku
110106|Hodogaya-ku
110107|Isogo-ku
110108|Kanazawa-ku
110109|Kohoku-ku
110110|Totsuka-ku
110111|Konan-ku
110112|Asahi-ku
110113|Midori-ku
110114|Seya-ku
110115|Sakae-ku
110116|Izumi-ku
110117|Aoba-ku
110118|Tsuzuki-ku
110301|Kawasaki-ku
110302|Saiwai-ku
110303|Nakahara-ku
110304|Takatsu-ku
110305|Tama-ku
110306|Miyamae-ku
110307|Asao-ku
111001|Midori-ku
111002|Chuou-ku
111003|Minami-ku
@JA_CITY_GUN_KU/12
1201|Chiba-shi
1202|Choshi-shi
1203|Ichikawa-shi
1204|Funabashi-shi
1205|Tateyama-shi
1206|Kisarazu-shi
1207|Matsudo-shi
1208|Noda-shi
1209|Sawara-shi
1210|Mobara-shi
1211|Narita-shi
1212|Sakura-shi
1213|Togane-shi
1214|Yokaichiba-shi
1215|Asahi-shi
1216|Narashino-shi
1217|Kashiwa-shi
1218|Katsuura-shi
1219|Ichihara-shi
1220|Nagareyama-shi
1221|Yachiyo-shi
1222|Abiko-shi
1223|Kamogawa-shi
1224|Kimitsu-shi
1225|Kamagaya-shi
1226|Futtu-shi
1227|Urayasu-shi
1228|Yotsukaido-shi
1229|Sodegaura-shi
1230|Yachimata-shi
1231|Inzai-shi
1232|Shiroi-shi
1233|Tomisato-shi
1234|Minamiboso-shi
1235|Sosa-shi
1236|Katori-shi
1237|Sanmu-shi
1238|Isumi-shi
1239|Oamishirasato-shi
12001|Awa-gun
12002|Isumi-gun
12003|Ichihara-gun
12004|Inba-gun
12005|Kaijo-gun
12006|Katori-gun
12007|Kimitsu-gun
12008|Sambu-gun
12009|Sosa-gun
12010|Chiba-gun
12011|Chosei-gun
12012|Higashikatsushika-gun
120101|Chuo-ku
120102|Hanamigawa-ku
120103|Inage-ku
120104|Wakaba-ku
120105|Midori-ku
120106|Mihama-ku
@JA_CITY_GUN_KU/13
1301|Urawa-shi
1302|Kawagoe-shi
1303|Kumagaya-shi
1304|Kawaguchi-shi
1305|Omiya-shi
1306|Gyoda-shi
1307|Chichibu-shi
1308|Tokorozawa-shi
1309|Hanno-shi
1310|Kazo-shi
1311|Honjo-shi
1312|Higashimatsuyama-shi
1313|Iwatsuki-shi
1314|Kasukabe-shi
1315|Sayama-shi
1316|Hanyu-shi
1317|Konosu-shi
1318|Fukaya-shi
1319|Ageo-shi
1320|Yono-shi
1321|Soka-shi
1322|Koshigaya-shi
1323|Warabi-shi
1324|Toda-shi
1325|Iruma-shi
1326|Hatogaya-shi
1327|Asaka-shi
1328|Shiki-shi
1329|Wako-shi
1330|Niiza-shi
1331|Okegawa-shi
1332|Kuki-shi
1333|Kitamoto-shi
1334|Yashio-shi
1335|Kamifukuoka-shi
1336|Fujimi-shi
1337|Misato-shi
1338|Hasuda-shi
1339|Sakado-shi
1340|Satte-shi
1341|Tsurugashima-shi
1342|Hidaka-shi
1343|Yoshikawa-shi
1344|Saitama-shi
1345|Fujimino-shi
1346|Shiraoka-shi
13001|Iruma-gun
13002|Osato-gun
13003|Kitaadachi-gun
13004|Kitakatsushika-gun
13005|Kitasaitama-gun
13006|Kodama-gun
13007|Chichibu-gun
13008|Hiki-gun
13009|Minamisaitama-gun
134401|Nishi-ku
134402|Kita-ku
134403|Omiya-ku
134404|Minuma-ku
134405|Chuo-ku
134406|Sakura-ku
134407|Urawa-ku
134408|Minami-ku
134409|Midori-ku
134410|Iwatsuki-ku
@JA_CITY_GUN_KU/14
1401|Mito-shi
1402|Hitachi-shi
1403|Tsuchiura-shi
1404|Koga-shi
1405|Ishioka-shi
1406|Shimodate-shi
1407|Yuki-shi
1408|Ryugasaki-shi
1409|Nakaminato-shi
1410|Shimotsuma-shi
1411|Mitsukaido-shi
1412|Hitachiota-shi
1413|Katsuta-shi
1414|Takahagi-shi
1415|Kitaibaraki-shi
1416|Kasama-shi
1417|Toride-shi
1418|Iwai-shi
1419|Ushiku-shi
1420|Tsukuba-shi
1421|Hitachinaka-shi
1422|Kashima-shi
1423|Itako-shi
1424|Moriya-shi
1425|Hitachiomiya-shi
1426|Naka-shi
1427|Chikusei-shi
1428|Bandou-shi
1429|Inashiki-shi
1430|Kasumigaura-shi
1431|Sakuragawa-shi
1432|Kamisu-shi
1433|Namegata-shi
1434|Hokota-shi
1435|Joso-shi
1436|Tsukubamirai-shi
1437|Omitama-shi
14001|Inashiki-gun
14002|Kashima-gun
14003|Kitasoma-gun
14004|Kuji-gun
14005|Sashima-gun
14006|Taga-gun
14007|Tsukuba-gun
14008|Naka-gun
14009|Namegata-gun
14010|Niihari-gun
14011|Nishiibaraki-gun
14012|Higashiibaraki-gun
14013|Makabe-gun
14014|Yuki-gun
@JA_CITY_GUN_KU/15
1501|Utsunomiya-shi
1502|Ashikaga-shi
1503|Tochigi-shi
1504|Sano-shi
1505|Kanuma-shi
1506|Nikko-shi
1507|Imaichi-shi
1508|Oyama-shi
1509|Mooka-shi
1510|Otawara-shi
1511|Yaita-shi
1512|Kuroiso-shi
1513|Nasushiobara-shi
1514|Sakura-shi
1515|Nasukarasuyama-shi
1516|Shimotsuke-shi
15001|Ashikaga-gun
15002|Aso-gun
15003|Kamitsuga-gun
15004|Kawachi-gun
15005|Shioya-gun
15006|Shimotsuga-gun
15007|Nasu-gun
15008|Haga-gun
@JA_CITY_GUN_KU/16
1601|Maebashi-shi
1602|Takasaki-shi
1603|Kiryu-shi
1604|Isesaki-shi
1605|Ota-shi
1606|Numata-shi
1607|Tatebayashi-shi
1608|Shibukawa-shi
1609|Fujioka-shi
1610|Tomioka-shi
1611|Annaka-shi
1612|Midori-shi
16001|Agatsuma-gun
16002|Usui-gun
16003|Ora-gun
16004|Kanra-gun
16005|Kitagumma-gun
16006|Gumma-gun
16007|Sawa-gun
16008|Seta-gun
16009|Tano-gun
16010|Tone-gun
16011|Nitta-gun
16012|Yamada-gun
@JA_CITY_GUN_KU/17
1701|Kofu-shi
1702|Fujiyoshida-shi
1703|Enzan-shi
1704|Tsuru-shi
1705|Yamanashi-shi
1706|Otsuki-shi
1707|Nirasaki-shi
1708|Minami-Alps
1709|Hokuto-shi
1710|Kai-shi
1711|Fuehuki-shi
1712|Uenohara-shi
1713|Koshu-shi
1714|Chuo-shi
17001|Kitakoma-gun
17002|Kitatsuru-gun
17003|Nakakoma-gun
17004|Nishiyatsushiro-gun
17005|Higashiyatsushiro-gun
17006|Higashiyamanashi-gun
17007|Minamikoma-gun
17008|Minamitsuru-gun
@JA_CITY_GUN_KU/18
1801|Shizuoka-shi
1802|Hamamatsu-shi
1803|Numadu-shi
1804|Shimizu-shi
1805|Atami-shi
1806|Mishima-shi
1807|Fujinomiya-shi
1808|Ito-shi
1809|Shimada-shi
1810|Yoshiwara-shi
1811|Iwata-shi
1812|Yaidu-shi
1813|Fuji-shi
1814|Kakegawa-shi
1815|Fujieda-shi
1816|Gotemba-shi
1817|Fukuroi-shi
1818|Tenryu-shi
1819|Hamakita-shi
1820|Shimoda-shi
1821|Susono-shi
1822|Kosai-shi
1823|Izu-shi
1824|Omaezaki-shi
1825|Kikugawa-shi
1826|Izunokuni-shi
1827|Makinohara-shi
18001|Abe-gun
18002|Inasa-gun
18003|Ihara-gun
18004|Iwata-gun
18005|Ogasa-gun
18006|Kamo-gun
18007|Shida-gun
18008|Shuchi-gun
18009|Sunto-gun
18010|Tagata-gun
18011|Haibara-gun
18012|Hamana-gun
18013|Fuji-gun
180101|Aoi-ku
180102|Suruga-ku
180103|Shimizu-ku
180201|Naka-ku
180202|Higashi-ku
180203|Nishi-ku
180204|Minami-ku
180205|Kita-ku
180206|Hamakita-ku
180207|Tenryu-ku
180208|Chuo-ku
180209|Hamana-ku
@JA_CITY_GUN_KU/19
1901|Gifu-shi
1902|Ogaki-shi
1903|Takayama-shi
1904|Tajimi-shi
1905|Seki-shi
1906|Nakatsugawa-shi
1907|Mino-shi
1908|Mizunami-shi
1909|Hashima-shi
1910|Ena-shi
1911|Minokamo-shi
1912|Toki-shi
1913|Kakamigahara-shi
1914|Kani-shi
1915|Yamagata-shi
1916|Mizuho-shi
1917|Hida-shi
1918|Motosu-shi
1919|Gujo-shi
1920|Gero-shi
1921|Kaizu-shi
19001|Ampachi-gun
19002|Inaba-gun
19003|Ibi-gun
19004|Ena-gun
19005|Ono-gun
19006|Kaizu-gun
19007|Kani-gun
19008|Kamo-gun
19009|Gujo-gun
19010|Toki-gun
19011|Hashima-gun
19012|Fuwa-gun
19013|Mashita-gun
19014|Mugi-gun
19015|Motosu-gun
19016|Yamagata-gun
19017|Yoro-gun
19018|Yoshiki-gun
@JA_CITY_GUN_KU/20
2001|Nagoya-shi
2002|Toyohashi-shi
2003|Okazaki-shi
2004|Ichinomiya-shi
2005|Seto-shi
2006|Handa-shi
2007|Kasugai-shi
2008|Toyokawa-shi
2009|Tsushima-shi
2010|Hekinan-shi
2011|Kariya-shi
2012|Toyota-shi
2013|Anjo-shi
2014|Nishio-shi
2015|Gamagori-shi
2016|Inuyama-shi
2017|Tokoname-shi
2018|Moriyama-shi
2019|Konan-shi
2020|Bisai-shi
2021|Komaki-shi
2022|Inazawa-shi
2023|Shinshiro-shi
2024|Tokai-shi
2025|Obu-shi
2026|Chita-shi
2027|Takahama-shi
2028|Chiryu-shi
2029|Owariasahi-shi
2030|Iwakura-shi
2031|Toyoake-shi
2032|Nissin-shi
2033|Tahara-shi
2034|Aisai-shi
2035|Kiyosu-shi
2036|Kitanagoya-shi
2037|Yatomi-shi
2038|Miyoshi-shi
2039|Ama-shi
2040|Nagakute-shi
20001|Aichi-gun
20002|Atsumi-gun
20003|Ama-gun
20004|Kitashitara-gun
20005|Chita-gun
20006|Nakashima-gun
20007|Nishikasugai-gun
20008|Nishikamo-gun
20009|Niwa-gun
20010|Nukata-gun
20011|Haguri-gun
20012|Hazu-gun
20013|Higashikasugai-gun
20014|Higashikamo-gun
20015|Hekikai-gun
20016|Hoi-gun
20017|Minamishitara-gun
20018|Yana-gun
200101|Chikusa-ku
200102|Higashi-ku
200103|Kita-ku
200104|Nishi-ku
200105|Nakamura-ku
200106|Naka-ku
200107|Showa-ku
200108|Mizuho-ku
200109|Atsuta-ku
200110|Nakagawa-ku
200111|Minato-ku
200112|Minami-ku
200113|Moriyama-ku
200114|Midori-ku
200115|Meito-ku
200116|Tenpaku-ku
@JA_CITY_GUN_KU/21
2101|Tsu-shi
2102|Yokkaichi-shi
2103|Ise-shi
2104|Matsusaka-shi
2105|Kuwana-shi
2106|Ueno-shi
2107|Suzuka-shi
2108|Nabari-shi
2109|Owase-shi
2110|Kameyama-shi
2111|Toba-shi
2112|Kumano-shi
2113|Hisai-shi
2114|Ujiyamada-shi
2115|Inabe-shi
2116|Shima-shi
2117|Iga-shi
21001|Age-gun
21002|Ano-gun
21003|Ayama-gun
21004|Iinan-gun
21005|Ichishi-gun
21006|Inabe-gun
21007|Kawage-gun
21008|Kitamuro-gun
21009|Kuwana-gun
21010|Shima-gun
21011|Suzuka-gun
21012|Taki-gun
21013|Naga-gun
21014|Mie-gun
21015|Minamimuro-gun
21016|Watarai-gun
@JA_CITY_GUN_KU/22
2201|Kyoto-shi
2202|Fukuchiyama-shi
2203|Maiduru-shi
2204|Ayabe-shi
2205|Uji-shi
2206|Miyazu-shi
2207|Kameoka-shi
2208|Joyo-shi
2209|Nagaokakyo-shi
2210|Muko-shi
2211|Yawata-shi
2212|Kyotanabe-shi
2213|Kyotango-shi
2214|Nantan-shi
2215|Kizugawa-shi
22001|Amada-gun
22002|Ikaruga-gun
22003|Otokuni-gun
22004|Kasa-gun
22005|Kitakuwada-gun
22006|Kuze-gun
22007|Kumano-gun
22008|Soraku-gun
22009|Takeno-gun
22010|Tsuduki-gun
22011|Naka-gun
22012|Funai-gun
22013|Minamikuwada-gun
22014|Yoza-gun
220101|Kita-ku
220102|Kamigyo-ku
220103|Sakyo-ku
220104|Nakagyo-ku
220105|Higashiyama-ku
220106|Shimogyo-ku
220107|Minami-ku
220108|Ukyo-ku
220109|Fushimi-ku
220110|Yamashina-ku
220111|Nishikyo-ku
@JA_CITY_GUN_KU/23
2301|Otsu-shi
2302|Hikone-shi
2303|Nagahama-shi
2304|Omihachiman-shi
2305|Yokaichi-shi
2306|Kusatsu-shi
2307|Moriyama-shi
2308|Ritto-shi
2309|Koka-shi
2310|Yasu-shi
2311|Konan-shi
2312|Takashima-shi
2313|Higashioumi-shi
2314|Maibara-shi
23001|Ika-gun
23002|Inukami-gun
23003|Echi-gun
23004|Gamou-gun
23005|Kanzaki-gun
23006|Kurita-gun
23007|Koka-gun
23008|Sakata-gun
23009|Shiga-gun
23010|Takashima-gun
23011|Higashiazai-gun
23012|Yasu-gun
@JA_CITY_GUN_KU/24
2401|Nara-shi
2402|Yamatotakada-shi
2403|Yamatokoriyama-shi
2404|Tenri-shi
2405|Kashihara-shi
2406|Sakurai-shi
2407|Gojo-shi
2408|Gose-shi
2409|Ikoma-shi
2410|Kashiba-shi
2411|Katsuragi-shi
2412|Uda-shi
24001|Ikoma-gun
24002|Uda-gun
24003|Uchi-gun
24004|Kitakatsuragi-gun
24005|Shiki-gun
24006|Soekami-gun
24007|Takaichi-gun
24008|Minamikatsuragi-gun
24009|Yamabe-gun
24010|Yoshino-gun
@JA_CITY_GUN_KU/25
2501|Osaka-shi
2502|Sakai-shi
2503|Kishiwada-shi
2504|Toyonaka-shi
2505|Fuse-shi
2506|Ikeda-shi
2507|Suita-shi
2508|Izumiotsu-shi
2509|Takatsuki-shi
2510|Kaiduka-shi
2511|Moriguchi-shi
2512|Hirakata-shi
2513|Ibaraki-shi
2514|Yao-shi
2515|Izumisano-shi
2516|Tondabayashi-shi
2517|Neyagawa-shi
2518|Kawachinagano-shi
2519|Hiraoka-shi
2520|Kawachi-shi
2521|Matsubara-shi
2522|Daito-shi
2523|Izumi-shi
2524|Mino-shi
2525|Kashiwara-shi
2526|Habikino-shi
2527|Kadoma-shi
2528|Settsu-shi
2529|Fujiidera-shi
2530|Takaishi-shi
2531|Higashiosaka-shi
2532|Sennan-shi
2533|Shijonawate-shi
2534|Katano-shi
2535|Osakasayama-shi
2536|Hannan-shi
25001|Kitakawachi-gun
25002|Sennan-gun
25003|Senboku-gun
25004|Toyono-gun
25005|Nakakawachi-gun
25006|Mishima-gun
25007|Minamikawachi-gun
250101|Kita-ku
250102|Miyakojima-ku
250103|Fukushima-ku
250104|Konohana-ku
250105|Higashi-ku
250106|Nishi-ku
250107|Minato-ku
250108|Taisho-ku
250109|Tennoji-ku
250110|Minami-ku
250111|Naniwa-ku
250112|Oyodo-ku
250113|Nishiyodogawa-ku
250114|Higashiyodogawa-ku
250115|Higashinari-ku
250116|Ikuno-ku
250117|Asahi-ku
250118|Joto-ku
250119|Abeno-ku
250120|Sumiyoshi-ku
250121|Higashisumiyoshi-ku
250122|Nishinari-ku
250123|Yodogawa-ku
250124|Tsurumi-ku
250125|Suminoe-ku
250126|Hirano-ku
250127|Chuo-ku
250201|Sakai-ku
250202|Naka-ku
250203|Higashi-ku
250204|Nishi-ku
250205|Minami-ku
250206|Kita-ku
250207|Mihara-ku
@JA_CITY_GUN_KU/26
2601|Wakayama-shi
2602|Shingu-shi
2603|Kainan-shi
2604|Tanabe-shi
2605|Gobo-shi
2606|Hashimoto-shi
2607|Arida-shi
2608|Kinokawa-shi
2609|Iwade-shi
26001|Arida-gun
26002|Ito-gun
26003|Kaiso-gun
26004|Naga-gun
26005|Nishimuro-gun
26006|Higashimuro-gun
26007|Hidaka-gun
@JA_CITY_GUN_KU/27
2701|Kobe-shi
2702|Himeji-shi
2703|Amagasaki-shi
2704|Akashi-shi
2705|Nishinomiya-shi
2706|Sumoto-shi
2707|Ashiya-shi
2708|Itami-shi
2709|Aioi-shi
2710|Toyooka-shi
2711|Kakogawa-shi
2712|Tatsuno-shi
2713|Ako-shi
2714|Nishiwaki-shi
2715|Takaraduka-shi
2716|Miki-shi
2717|Takasago-shi
2718|Kawanishi-shi
2719|Ono-shi
2720|Sanda-shi
2721|Kasai-shi
2722|Sasayama-shi
2723|Yabu-shi
2724|Tanba-shi
2725|Minamiawaji-shi
2726|Asago-shi
2727|Awaji-shi
2728|Shiso-shi
2729|Kato-shi
2730|Tatsuno-shi
2731|Tanbasasayama-shi
27001|Akou-gun
27002|Asago-gun
27003|Arima-gun
27004|Izushi-gun
27005|Ibo-gun
27006|Innami-gun
27007|Kako-gun
27008|Kasai-gun
27009|Kato-gun
27010|Kawabe-gun
27011|Kanzaki-gun
27012|Kinosaki-gun
27013|Sayo-gun
27014|Shikama-gun
27015|Shiso-gun
27016|Taka-gun
27017|Taki-gun
27018|Tsuna-gun
27019|Hikami-gun
27020|Mikata-gun
27021|Mino-gun
27022|Mihara-gun
27023|Muko-gun
27024|Yabu-gun
270101|Higashinada-ku
270102|Nada-ku
270103|Hyogo-ku
270104|Nagata-ku
270105|Suma-ku
270106|Tarumi-ku
270107|Kita-ku
270108|Chuo-ku
270109|Nishi-ku
270110|Fukiai-ku
270111|Ikuta-ku
@JA_CITY_GUN_KU/28
2801|Toyama-shi
2802|Takaoka-shi
2803|Shinminato-shi
2804|Uodu-shi
2805|Himi-shi
2806|Namerikawa-shi
2807|Kurobe-shi
2808|Tonami-shi
2809|Oyabe-shi
2810|Nanto-shi
2811|Imizu-shi
28001|Imizu-gun
28002|Kaminiikawa-gun
28003|Shimoniikawa-gun
28004|Nakaniikawa-gun
28005|Nishitonami-gun
28006|Nei-gun
28007|Himi-gun
28008|Higashitonami-gun
@JA_CITY_GUN_KU/29
2901|Fukui-shi
2902|Tsuruga-shi
2903|Takefu-shi
2904|Obama-shi
2905|Ono-shi
2906|Katsuyama-shi
2907|Sabae-shi
2908|Awara-shi
2909|Echizen-shi
2910|Sakai-shi
29001|Asuwa-gun
29002|Imadate-gun
29003|Oi-gun
29004|Ono-gun
29005|Onyu-gun
29006|Sakai-gun
29007|Tsuruga-gun
29008|Nanjo-gun
29009|Nyuu-gun
29010|Mikata-gun
29011|Yoshida-gun
29012|Mikatakaminaka-gun
@JA_CITY_GUN_KU/30
3001|Kanazawa-shi
3002|Nanao-shi
3003|Komatsu-shi
3004|Wajima-shi
3005|Suzu-shi
3006|Kaga-shi
3007|Hakui-shi
3008|Matsuto-shi
3009|Kahoku-shi
3010|Hakusan-shi
3011|Nomi-shi
3012|Nonoichi-shi
30001|Ishikawa-gun
30002|Enuma-gun
30003|Kashima-gun
30004|Kahoku-gun
30005|Suzu-gun
30006|Nomi-gun
30007|Hakui-gun
30008|Fugeshi-gun
30009|Housu-gun
@JA_CITY_GUN_KU/31
3101|Okayama-shi
3102|Kurashiki-shi
3103|Tsuyama-shi
3104|Tamano-shi
3105|Kojima-shi
3106|Tamashima-shi
3107|Kasaoka-shi
3108|saidaiji-shi
3109|Ibara-shi
3110|Soja-shi
3111|Takahashi-shi
3112|Niimi-shi
3113|Bizen-shi
3114|Setouchi-shi
3115|Akaiwa-shi
3116|Maniwa-shi
3117|Mimasaka-shi
3118|Asakuchi-shi
31001|Aida-gun
31002|Akaiwa-gun
31003|Asakuchi-gun
31004|Atetsu-gun
31005|Oku-gun
31006|Oda-gun
31007|Katsuta-gun
31008|Kawakami-gun
31009|Kibi-gun
31010|Kume-gun
31011|Kojima-gun
31012|Shitsuki-gun
31013|Jodo-gun
31014|Jobo-gun
31015|Tsukubo-gun
31016|Tomada-gun
31017|Maniwa-gun
31018|Mitsu-gun
31019|Wake-gun
31020|Kaga-gun
310101|Kita-ku
310102|Naka-ku
310103|Higashi-ku
310104|Minami-ku
@JA_CITY_GUN_KU/32
3201|Matsue-shi
3202|Hamada-shi
3203|Izumo-shi
3204|Masuda-shi
3205|Oda-shi
3206|Yasugi-shi
3207|Gotsu-shi
3208|Hirata-shi
3209|Unnan-shi
32001|Ano-gun
32002|Ama-gun
32003|Iishi-gun
32004|Ochi-gun
32005|Ohara-gun
32006|Oki-gun
32007|Ochi-gun
32008|Kanoashi-gun
32009|Suki-gun
32010|Chibu-gun
32011|Naka-gun
32012|Nita-gun
32013|Nima-gun
32014|Nogi-gun
32015|Hikawa-gun
32016|Mino-gun
32017|Yatsuka-gun
33001|Asa-gun
@JA_CITY_GUN_KU/33
3301|Yamaguchi-shi
3302|Shimonoseki-shi
3303|Ube-shi
3304|Hagi-shi
3305|Tokuyama-shi
3306|Hofu-shi
3307|Kudamatsu-shi
3308|Iwakuni-shi
3309|Onoda-shi
3310|Hikari-shi
3311|Nagato-shi
3312|Yanai-shi
3313|Mine-shi
3314|Shinnan01yo-shi
3315|Shunan-shi
3316|San01yoonoda-shi
33002|Abu-gun
33003|Oshima-gun
33004|Otsu-gun
33005|Kuga-gun
33006|Kumage-gun
33007|Saba-gun
33008|Tsuno-gun
33009|Toyoura-gun
33010|Mine-gun
33011|Yoshiki-gun
@JA_CITY_GUN_KU/34
3401|Tottori-shi
3402|Kurayoshi-shi
3403|Yonago-shi
3404|Sakaiminato-shi
34001|Iwami-gun
34002|Ketaka-gun
34003|Saihaku-gun
34004|Tohaku-gun
34005|Hino-gun
34006|Yazu-gun
@JA_CITY_GUN_KU/35
3501|Hiroshima-shi
3502|Kure-shi
3503|Takehara-shi
3504|Mihara-shi
3505|Onomichi-shi
3506|Innoshima-shi
3507|Matsunaga-shi
3508|Fukuyama-shi
3509|Fuchu-shi
3510|Miyoshi-shi
3511|Syoubara-shi
3512|Otake-shi
3513|Higashihiroshima-shi
3514|Hatsukaichi-shi
3515|Akitakata-shi
3516|Etajima-shi
35001|Aki-gun
35002|Asa-gun
35003|Ashina-gun
35004|Kamo-gun
35005|Konu-gun
35006|Saeki-gun
35007|Jinseki-gun
35008|Sera-gun
35009|Takata-gun
35010|Toyota-gun
35011|Numakuma-gun
35012|Hiba-gun
35013|Fukayasu-gun
35014|Futami-gun
35015|Mitsugi-gun
35016|Yamagata-gun
350101|Naka-ku
350102|Higashi-ku
350103|Minami-ku
350104|Nishi-ku
350105|Asaminami-ku
350106|Asakita-ku
350107|Aki-ku
350108|Saeki-ku
@JA_CITY_GUN_KU/36
3601|Takamatsu-shi
3602|Marugame-shi
3603|Sakaide-shi
3604|Zentsuji-shi
3605|Kan01onji-shi
3606|Sanuki-shi
3607|Higashikagawa-shi
3608|Mitoyo-shi
36001|Ayauta-gun
36002|Okawa-gun
36003|Kagawa-gun
36004|Kita-gun
36005|Syozu-gun
36006|Nakatado-gun
36007|Mitoyo-gun
@JA_CITY_GUN_KU/37
3701|Tokushima-shi
3702|Naruto-shi
3703|Komatsushima-shi
3704|Anan-shi
3705|Yoshinogawa-shi
3706|Awa-shi
3707|Mima-shi
3708|Miyoshi-shi
37001|Awa-gun
37002|Itano-gun
37003|Oe-gun
37004|Kaifu-gun
37005|Katsuura-gun
37006|Naka-gun
37007|Myozai-gun
37008|Myodo-gun
37009|Mima-gun
37010|Miyoshi-gun
@JA_CITY_GUN_KU/38
3801|Matsuyama-shi
3802|Imabari-shi
3803|Uwajima-shi
3804|Yawatahama-shi
3805|Niihama-shi
3806|Saijo-shi
3807|Ozu-shi
3808|Iyomishima-shi
3809|Kawanoe-shi
3810|Iyo-shi
3811|Hojo-shi
3812|Toyo-shi
3813|Shikokuchuo-shi
3814|Seiyo-shi
3815|Toon-shi
38001|Iyo-gun
38002|Uma-gun
38003|Ochi-gun
38004|Onsen-gun
38005|Kamiukena-gun
38006|Kita-gun
38007|Kitauwa-gun
38008|Shuso-gun
38009|Nii-gun
38010|Nishiuwa-gun
38011|Higashiuwa-gun
38012|Minamiuwa-gun
@JA_CITY_GUN_KU/39
3901|Kochi-shi
3902|Muroto-shi
3903|Aki-shi
3904|Tosa-shi
3905|Susaki-shi
3906|Nakamura-shi
3907|Sukumo-shi
3908|Tosashimizu-shi
3909|Nankoku-shi
3910|Shimanto-shi
3911|Konan-shi
3912|Kami-shi
39001|Agawa-gun
39002|Aki-gun
39003|Kami-gun
39004|Takaoka-gun
39005|Tosa-gun
39006|Nagaoka-gun
39007|Hata-gun
@JA_CITY_GUN_KU/40
4001|Fukuoka-shi
4002|Kokura-shi
4003|Moji-shi
4004|Yahata-shi
4005|Tobata-shi
4006|Wakamatsu-shi
4007|Kurume-shi
4008|Omuta-shi
4009|Noogata-shi
4010|Iizuka-shi
4011|Tagawa-shi
4012|Yanagawa-shi
4013|Amagi-shi
4014|Yamada-shi
4015|Yame-shi
4016|Chikugo-shi
4017|Okawa-shi
4018|Yukuhashi-shi
4019|Buzen-shi
4020|Nakama-shi
4021|Kitakyushu-shi
4022|Ogoori-shi
4023|Kasuga-shi
4024|Chikushino-shi
4025|Onojo-shi
4026|Munakata-shi
4027|Dazaifu-shi
4028|Maebaru-shi
4029|Koga-shi
4030|Fukutsu-shi
4031|Ukiha-shi
4032|Miyawaka-shi
4033|Kama-shi
4034|Asakura-shi
4035|Miyama-shi
4036|Itoshima-shi
4037|Nakagawa-shi
40001|Asakura-gun
40002|Itoshima-gun
40003|Ukiha-gun
40004|Onga-gun
40005|Kasuya-gun
40006|Kaho-gun
40007|Kurate-gun
40008|Sawara-gun
40009|Tagawa-gun
40010|Chikushi-gun
40011|Chikujo-gun
40012|Mii-gun
40013|Miike-gun
40014|Mizuma-gun
40015|Miyako-gun
40016|Munakata-gun
40017|Yamato-gun
40018|Yame-gun
400101|Higashi-ku
400102|Hakata-ku
400103|Chuo-ku
400104|Minami-ku
400105|Nishi-ku
400106|Jonan-ku
400107|Sawara-ku
402101|Moji-ku
402102|Wakamatsu-ku
402103|Tobata-ku
402104|Kokurakita-ku
402105|Kokuraminami-ku
402106|Yahatahigashi-ku
402107|Yahatanishi-ku
402108|Yahata-ku
402109|Kokura-ku
@JA_CITY_GUN_KU/41
4101|Saga-shi
4102|Karatsu-shi
4103|Tosu-shi
4104|Taku-shi
4105|Imari-shi
4106|Takeo-shi
4107|Kashima-shi
4108|Ogi-shi
4109|Ureshino-shi
4110|Kanzaki-shi
41001|Ogi-gun
41002|Kanzaki-gun
41003|Kishima-gun
41004|Saga-gun
41005|Nishimatsuura-gun
41006|Higashimatsuura-gun
41007|Fujitsu-gun
41008|Miyaki-gun
@JA_CITY_GUN_KU/42
4201|Nagasaki-shi
4202|Sasebo-shi
4203|Shimabara-shi
4204|Isahaya-shi
4205|Omura-shi
4206|Fukue-shi
4207|Hirado-shi
4208|Matsuura-shi
4209|Tsushima-shi
4210|Iki-shi
4211|Goto-shi
4212|Saikai-shi
4213|Unzen-shi
4214|Minamishimabara-shi
42001|Iki-gun
42002|Kamiagata-gun
42003|Kitatakaki-gun
42004|Kitamatsuura-gun
42005|Shimoagata-gun
42006|Nishisonogi-gun
42007|Higashisonogi-gun
42008|Minamitakaki-gun
42009|Minamimatsuura-gun
@JA_CITY_GUN_KU/43
4301|Kumamoto-shi
4302|Yatsushiro-shi
4303|Hitoyoshi-shi
4304|Arao-shi
4305|Minamata-shi
4306|Tamana-shi
4307|Hondo-shi
4308|Yamaga-shi
4309|Ushibuka-shi
4310|Kikuchi-shi
4311|Uto-shi
4312|Kamiamakusa-shi
4313|Uki-shi
4314|Aso-shi
4315|Amakusa-shi
4316|Koshi-shi
43001|Ashikita-gun
43002|Aso-gun
43003|Amakusa-gun
43004|Uto-gun
43005|Kamimashiki-gun
43006|Kamoto-gun
43007|Kikuchi-gun
43008|Kuma-gun
43009|Shimomashiki-gun
43010|Tamana-gun
43011|Hotaku-gun
43012|Yatsushiro-gun
430101|Chuo-ku
430102|Higashi-ku
430103|Nishi-ku
430104|Minami-ku
430105|Kita-ku
@JA_CITY_GUN_KU/44
4401|Oita-shi
4402|Beppu-shi
4403|Nakatsu-shi
4404|Hita-shi
4405|Saiki-shi
4406|Usuki-shi
4407|Tsukumi-shi
4408|Taketa-shi
4409|Tsurusaki-shi
4410|Bungotakada-shi
4411|Kitsuki-shi
4412|Usa-shi
4413|Bungoono-shi
4414|Yufu-shi
4415|Kunisaki-shi
44001|Usa-gun
44002|Oita-gun
44003|Ono-gun
44004|Kitaamabe-gun
44005|Kusu-gun
44006|Shimoge-gun
44007|Naoiri-gun
44008|Nishikunisaki-gun
44009|Hayami-gun
44010|Higashikunisaki-gun
44011|Hita-gun
44012|Minamiamabe-gun
@JA_CITY_GUN_KU/45
4501|Miyazaki-shi
4502|Miyakonojo-shi
4503|Nobeoka-shi
4504|Nichinan-shi
4505|Kobayashi-shi
4506|Hyuga-shi
4507|Kushima-shi
4508|Saito-shi
4509|Ebino-shi
45001|Kitamorokata-gun
45002|Koyu-gun
45003|Nishiusuki-gun
45004|Nishimorokata-gun
45005|Higashiusuki-gun
45006|Higashimorokata-gun
45007|Minaminaka-gun
45008|Miyazaki-gun
@JA_CITY_GUN_KU/46
4601|Kagoshima-shi
4602|Sendai-shi
4603|Kanoya-shi
4604|Makurazaki-shi
4605|Kushikino-shi
4606|Akune-shi
4607|Izumi-shi
4608|Naze-shi
4609|Okuchi-shi
4610|Ibusuki-shi
4611|Kaseda-shi
4612|Kokubu-shi
4613|Taniyama-shi
4614|Nishinoomote-shi
4615|Tarumizu-shi
4616|Satsumasendai-shi
4617|Hioki-shi
4618|Soo-shi
4619|Kirishima-shi
4620|Ichikikushikino-shi
4621|Minamisatsuma-shi
4622|Shibushi-shi
4623|Amami-shi
4624|Minamikyushu-shi
4625|Isa-shi
4626|Aira-shi
46001|Aira-gun
46002|Isa-gun
46003|Izumi-gun
46004|Ibusuki-gun
46005|Oshima-gun
46006|Kagoshima-gun
46007|Kawanabe-gun
46008|Kimotsuki-gun
46009|Kumage-gun
46010|Satsuma-gun
46011|Soo-gun
46012|Hioki-gun
@JA_CITY_GUN_KU/47
4701|Naha-shi
4702|Ishikawa-shi
4703|Hirara-shi
4704|Ishigaki-shi
4705|Koza-shi
4706|Ginowan-shi
4707|Gushikawa-shi
4708|Nago-shi
4709|Urasoe-shi
4710|Itoman-shi
4711|Okinawa-shi
4712|Tomigusuku-shi
4713|Uruma-shi
4714|Miyakojima-shi
4715|Nanjo-shi
47001|Kunigami-gun
47002|Shimajiri-gun
47003|Nakagami-gun
47004|Miyako-gun
47005|Yaeyama-gun
"""
}
