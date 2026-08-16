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
