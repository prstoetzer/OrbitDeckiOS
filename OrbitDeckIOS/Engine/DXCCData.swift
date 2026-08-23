import Foundation
import CoreLocation

struct DXCCEntity: Identifiable, Hashable, Sendable {
    let prefix: String
    let name: String
    let latitude: Double
    let longitude: Double
    var id: String { prefix }
}

enum DXCCData {
    static let entities: [DXCCEntity] = [
        .init(prefix: "YA", name: "Afghanistan", latitude: 33.9, longitude: 67.7),
        .init(prefix: "3B6", name: "Agalega & St. Brandon Is.", latitude: -10.4, longitude: 56.6),
        .init(prefix: "OH0", name: "Aland Is.", latitude: 60.2, longitude: 20),
        .init(prefix: "KL", name: "Alaska", latitude: 64.2, longitude: -149.5),
        .init(prefix: "ZA", name: "Albania", latitude: 41.2, longitude: 20.2),
        .init(prefix: "7R", name: "Algeria (People's Dem Rep of)", latitude: 28, longitude: 2.6),
        .init(prefix: "KH8", name: "American Samoa", latitude: -14.3, longitude: -170.7),
        .init(prefix: "FT/Z", name: "Amsterdam & St. Paul Is.", latitude: -37.8, longitude: 77.6),
        .init(prefix: "VU4", name: "Andaman & Nicobar Is.", latitude: 11.7, longitude: 92.7),
        .init(prefix: "C3", name: "Andorra", latitude: 42.5, longitude: 1.5),
        .init(prefix: "D2", name: "Angola", latitude: -11.2, longitude: 17.9),
        .init(prefix: "VP2E", name: "Anguilla", latitude: 18.2, longitude: -63.1),
        .init(prefix: "3C0", name: "Annobon I.", latitude: -1.4, longitude: 5.6),
        .init(prefix: "CE9/KC4^", name: "Antarctica", latitude: -82, longitude: 0),
        .init(prefix: "V2", name: "Antigua & Barbuda", latitude: 17.1, longitude: -61.8),
        .init(prefix: "LO", name: "Argentina", latitude: -38.4, longitude: -63.6),
        .init(prefix: "EK", name: "Armenia", latitude: 40.1, longitude: 45),
        .init(prefix: "P4", name: "Aruba", latitude: 12.5, longitude: -70),
        .init(prefix: "ZD8", name: "Ascension I.", latitude: -7.9, longitude: -14.4),
        .init(prefix: "UA", name: "Asiatic Russia", latitude: 60, longitude: 90),
        .init(prefix: "FO", name: "Austral I.", latitude: -23.4, longitude: -149.5),
        .init(prefix: "VK", name: "Australia", latitude: -25.3, longitude: 133.8),
        .init(prefix: "OE", name: "Austria", latitude: 47.6, longitude: 14.1),
        .init(prefix: "YV0", name: "Aves I.", latitude: 15.7, longitude: -63.6),
        .init(prefix: "4J", name: "Azerbaijan", latitude: 40.4, longitude: 47.9),
        .init(prefix: "CU", name: "Azores", latitude: 37.7, longitude: -25.7),
        .init(prefix: "C6", name: "Bahamas (Commonwealth of the)", latitude: 24.9, longitude: -76.8),
        .init(prefix: "A9", name: "Bahrain", latitude: 26, longitude: 50.6),
        .init(prefix: "KH1", name: "Baker & Howland Is.", latitude: 0.8, longitude: -176.6),
        .init(prefix: "EA6", name: "Balearic Is.", latitude: 39.6, longitude: 2.9),
        .init(prefix: "T33", name: "Banaba I. (Ocean I.)", latitude: -0.9, longitude: 169.5),
        .init(prefix: "S2", name: "Bangladesh", latitude: 23.7, longitude: 90.4),
        .init(prefix: "8P", name: "Barbados", latitude: 13.2, longitude: -59.5),
        .init(prefix: "EU", name: "Belarus (Republic of)", latitude: 53.7, longitude: 27.9),
        .init(prefix: "ON", name: "Belgium", latitude: 50.5, longitude: 4.5),
        .init(prefix: "V3", name: "Belize", latitude: 17.2, longitude: -88.5),
        .init(prefix: "TY", name: "Benin", latitude: 9.3, longitude: 2.3),
        .init(prefix: "VP9", name: "Bermuda", latitude: 32.3, longitude: -64.8),
        .init(prefix: "A5", name: "Bhutan", latitude: 27.5, longitude: 90.4),
        .init(prefix: "CP", name: "Bolivia", latitude: -16.3, longitude: -63.6),
        .init(prefix: "PJ4", name: "Bonaire", latitude: 12.2, longitude: -68.3),
        .init(prefix: "E7", name: "Bosnia-Herzegovina", latitude: 43.9, longitude: 17.7),
        .init(prefix: "A2", name: "Botswana (Republic of)", latitude: -22.3, longitude: 24.7),
        .init(prefix: "3Y", name: "Bouvet", latitude: -54.4, longitude: 3.4),
        .init(prefix: "PP", name: "Brazil", latitude: -14.2, longitude: -51.9),
        .init(prefix: "VP2V", name: "British Virgin Is.", latitude: 18.4, longitude: -64.6),
        .init(prefix: "V8", name: "Brunei Darussalam", latitude: 4.5, longitude: 114.7),
        .init(prefix: "LZ", name: "Bulgaria", latitude: 42.7, longitude: 25.5),
        .init(prefix: "XT", name: "Burkina Faso", latitude: 12.2, longitude: -1.6),
        .init(prefix: "9U", name: "Burundi", latitude: -3.4, longitude: 29.9),
        .init(prefix: "T31", name: "C. Kiribati (British Phoenix Is.)", latitude: -3.4, longitude: -172),
        .init(prefix: "D4", name: "Cabo Verde (Rep of)", latitude: 16, longitude: -24),
        .init(prefix: "XU", name: "Cambodia", latitude: 12.5, longitude: 105),
        .init(prefix: "TJ", name: "Cameroon", latitude: 7.4, longitude: 12.4),
        .init(prefix: "VA", name: "Canada", latitude: 56, longitude: -106),
        .init(prefix: "EA8", name: "Canary Is.", latitude: 28.3, longitude: -15.6),
        .init(prefix: "ZF", name: "Cayman Is.", latitude: 19.3, longitude: -81.2),
        .init(prefix: "TL", name: "Central Africa", latitude: 6.6, longitude: 20.9),
        .init(prefix: "EA9", name: "Ceuta & Melilla", latitude: 35.9, longitude: -5.3),
        .init(prefix: "TT", name: "Chad", latitude: 15.4, longitude: 18.7),
        .init(prefix: "VQ9", name: "Chagos Is.", latitude: -7.3, longitude: 72.4),
        .init(prefix: "ZL7", name: "Chatham Is.", latitude: -44, longitude: -176.5),
        .init(prefix: "FK", name: "Chesterfield Is.", latitude: -19.9, longitude: 158.3),
        .init(prefix: "CA", name: "Chile", latitude: -35.7, longitude: -71.5),
        .init(prefix: "B", name: "China", latitude: 35.9, longitude: 104.2),
        .init(prefix: "VK9", name: "Christmas I.", latitude: -10.5, longitude: 105.6),
        .init(prefix: "FO#36", name: "Clipperton I.", latitude: 10.3, longitude: -109.2),
        .init(prefix: "VK9#38", name: "Cocos (Keeling) Is.", latitude: -12.2, longitude: 96.9),
        .init(prefix: "TI9", name: "Cocos I.", latitude: 5.5, longitude: -87.1),
        .init(prefix: "HJ", name: "Colombia", latitude: 4.6, longitude: -74.1),
        .init(prefix: "D6", name: "Comoros", latitude: -11.6, longitude: 43.3),
        .init(prefix: "3D2", name: "Conway Reef", latitude: -21.8, longitude: 174.7),
        .init(prefix: "TK", name: "Corsica", latitude: 42, longitude: 9),
        .init(prefix: "TI", name: "Costa Rica", latitude: 9.7, longitude: -84),
        .init(prefix: "TU", name: "Cote d'Ivoire", latitude: 7.5, longitude: -5.5),
        .init(prefix: "SV9", name: "Crete", latitude: 35.2, longitude: 24.9),
        .init(prefix: "9A", name: "Croatia", latitude: 45.1, longitude: 15.2),
        .init(prefix: "FT/W", name: "Crozet I.", latitude: -46.4, longitude: 51.9),
        .init(prefix: "CL", name: "Cuba", latitude: 21.5, longitude: -79.5),
        .init(prefix: "PJ2", name: "Curacao", latitude: 12.2, longitude: -69),
        .init(prefix: "5B", name: "Cyprus", latitude: 35.1, longitude: 33.4),
        .init(prefix: "OK", name: "Czech Republic", latitude: 49.8, longitude: 15.5),
        .init(prefix: "P5", name: "Democratic People's Rep. of Korea", latitude: 40.3, longitude: 127.5),
        .init(prefix: "9O", name: "Democratic Republic of the Congo", latitude: -4, longitude: 21.8),
        .init(prefix: "OU", name: "Denmark", latitude: 56, longitude: 10),
        .init(prefix: "KP5", name: "Desecheo I.", latitude: 18.4, longitude: -67.5),
        .init(prefix: "J2", name: "Djibouti", latitude: 11.8, longitude: 42.6),
        .init(prefix: "SV5", name: "Dodecanese", latitude: 36.4, longitude: 27.2),
        .init(prefix: "J7", name: "Dominica", latitude: 15.4, longitude: -61.4),
        .init(prefix: "HI", name: "Dominican Republic", latitude: 18.7, longitude: -70.2),
        .init(prefix: "VP6", name: "Ducie I.", latitude: -24.7, longitude: -124.8),
        .init(prefix: "T32", name: "E. Kiribati (Line Is.)", latitude: 1.9, longitude: -157.4),
        .init(prefix: "9M6", name: "East Malaysia", latitude: 2.4, longitude: 113.9),
        .init(prefix: "CE0", name: "Easter I.", latitude: -27.1, longitude: -109.4),
        .init(prefix: "HC", name: "Ecuador", latitude: -1.8, longitude: -78.2),
        .init(prefix: "SU", name: "Egypt", latitude: 26.8, longitude: 30.8),
        .init(prefix: "YS", name: "El Salvador", latitude: 13.8, longitude: -88.9),
        .init(prefix: "3C", name: "Equatorial Guinea", latitude: 1.6, longitude: 10.4),
        .init(prefix: "E3", name: "Eritrea", latitude: 15.2, longitude: 39.8),
        .init(prefix: "ES", name: "Estonia", latitude: 58.6, longitude: 25),
        .init(prefix: "ET", name: "Ethiopia", latitude: 9.1, longitude: 40.5),
        .init(prefix: "UA#54", name: "European Russia", latitude: 56, longitude: 44),
        .init(prefix: "VP8", name: "Falkland Is.", latitude: -51.7, longitude: -59.2),
        .init(prefix: "OY", name: "Faroe Is.", latitude: 62, longitude: -6.9),
        .init(prefix: "PP0", name: "Fernando de Noronha", latitude: -3.85, longitude: -32.4),
        .init(prefix: "3D2#176", name: "Fiji (Republic of)", latitude: -18.1, longitude: 178.4),
        .init(prefix: "OF", name: "Finland", latitude: 64, longitude: 26),
        .init(prefix: "F", name: "France", latitude: 46.6, longitude: 2.2),
        .init(prefix: "R1/F", name: "Franz Josef Land", latitude: 80.7, longitude: 54),
        .init(prefix: "FY", name: "French Guiana", latitude: 4, longitude: -53),
        .init(prefix: "FO#175", name: "French Polynesia", latitude: -17.7, longitude: -149.4),
        .init(prefix: "TR", name: "Gabon", latitude: -0.8, longitude: 11.6),
        .init(prefix: "HC8", name: "Galapagos Is.", latitude: -0.9, longitude: -90.5),
        .init(prefix: "C5", name: "Gambia (Republic of the)", latitude: 13.4, longitude: -15.3),
        .init(prefix: "4L", name: "Georgia", latitude: 42.3, longitude: 43.4),
        .init(prefix: "DA", name: "Germany (Federal Rep of)", latitude: 51.2, longitude: 10.4),
        .init(prefix: "9G", name: "Ghana", latitude: 7.9, longitude: -1),
        .init(prefix: "ZB2", name: "Gibraltar", latitude: 36.1, longitude: -5.3),
        .init(prefix: "FT/G", name: "Glorioso Is.", latitude: -11.6, longitude: 47.3),
        .init(prefix: "SV", name: "Greece", latitude: 39.1, longitude: 21.8),
        .init(prefix: "OX", name: "Greenland", latitude: 72, longitude: -40),
        .init(prefix: "J3", name: "Grenada", latitude: 12.1, longitude: -61.7),
        .init(prefix: "FG", name: "Guadeloupe", latitude: 16.2, longitude: -61.6),
        .init(prefix: "KH2", name: "Guam", latitude: 13.4, longitude: 144.8),
        .init(prefix: "KG4", name: "Guantanamo Bay", latitude: 19.9, longitude: -75.1),
        .init(prefix: "TG", name: "Guatemala", latitude: 15.8, longitude: -90.2),
        .init(prefix: "GU", name: "Guernsey", latitude: 49.5, longitude: -2.6),
        .init(prefix: "3X", name: "Guinea", latitude: 9.9, longitude: -11.8),
        .init(prefix: "J5", name: "Guinea-Bissau", latitude: 12, longitude: -15),
        .init(prefix: "8R", name: "Guyana", latitude: 4.9, longitude: -58.9),
        .init(prefix: "HH", name: "Haiti", latitude: 19.1, longitude: -72.3),
        .init(prefix: "KH6", name: "Hawaii", latitude: 20.8, longitude: -156.3),
        .init(prefix: "VK#111", name: "Heard I.", latitude: -53.1, longitude: 73.5),
        .init(prefix: "HQ", name: "Honduras", latitude: 15.2, longitude: -86.2),
        .init(prefix: "VR", name: "Hong Kong", latitude: 22.3, longitude: 114.2),
        .init(prefix: "HA", name: "Hungary", latitude: 47.2, longitude: 19.5),
        .init(prefix: "4U_ITU", name: "ITU HQ", latitude: 46.2, longitude: 6.1),
        .init(prefix: "TF", name: "Iceland", latitude: 64.9, longitude: -19),
        .init(prefix: "VU", name: "India", latitude: 20.6, longitude: 79),
        .init(prefix: "YB", name: "Indonesia", latitude: -2.5, longitude: 118),
        .init(prefix: "EP", name: "Iran (Islamic Repub of)", latitude: 32.4, longitude: 53.7),
        .init(prefix: "YI", name: "Iraq", latitude: 33.2, longitude: 43.7),
        .init(prefix: "EI", name: "Ireland", latitude: 53.4, longitude: -8.2),
        .init(prefix: "GD", name: "Isle of Man", latitude: 54.2, longitude: -4.5),
        .init(prefix: "4X", name: "Israel", latitude: 31, longitude: 34.9),
        .init(prefix: "I", name: "Italy", latitude: 41.9, longitude: 12.6),
        .init(prefix: "6Y", name: "Jamaica", latitude: 18.1, longitude: -77.3),
        .init(prefix: "JX", name: "Jan Mayen", latitude: 71, longitude: -8.3),
        .init(prefix: "JA", name: "Japan", latitude: 36.2, longitude: 138.3),
        .init(prefix: "GJ", name: "Jersey", latitude: 49.2, longitude: -2.1),
        .init(prefix: "KH3", name: "Johnston I.", latitude: 16.7, longitude: -169.5),
        .init(prefix: "JY", name: "Jordan", latitude: 31.3, longitude: 36.2),
        .init(prefix: "CE0#125", name: "Juan Fernandez Is.", latitude: -33.6, longitude: -78.8),
        .init(prefix: "FT/J", name: "Juan de Nova, Europa", latitude: -17.1, longitude: 42.7),
        .init(prefix: "UA2", name: "Kaliningrad", latitude: 54.7, longitude: 20.5),
        .init(prefix: "UN", name: "Kazakhstan", latitude: 48, longitude: 66.9),
        .init(prefix: "5Y", name: "Kenya", latitude: 0.2, longitude: 37.9),
        .init(prefix: "FT/X", name: "Kerguelen Is.", latitude: -49.4, longitude: 69.4),
        .init(prefix: "ZL8", name: "Kermadec Is.", latitude: -29.3, longitude: -177.9),
        .init(prefix: "3DA", name: "Kingdom of Eswatini", latitude: -26.5, longitude: 31.5),
        .init(prefix: "HL", name: "Korea (Republic of)", latitude: 36.4, longitude: 127.9),
        .init(prefix: "KH7K", name: "Kure I.", latitude: 28.4, longitude: -178.3),
        .init(prefix: "9K", name: "Kuwait", latitude: 29.3, longitude: 47.6),
        .init(prefix: "EX", name: "Kyrgyz Republic", latitude: 41.2, longitude: 74.8),
        .init(prefix: "VU7", name: "Lakshadweep Is.", latitude: 10.6, longitude: 72.6),
        .init(prefix: "XW", name: "Lao People's Democratic Rep", latitude: 19.9, longitude: 102.5),
        .init(prefix: "YL", name: "Latvia", latitude: 56.9, longitude: 24.6),
        .init(prefix: "OD", name: "Lebanon", latitude: 33.9, longitude: 35.9),
        .init(prefix: "7P", name: "Lesotho", latitude: -29.6, longitude: 28.2),
        .init(prefix: "EL", name: "Liberia", latitude: 6.4, longitude: -9.4),
        .init(prefix: "5A", name: "Libya", latitude: 27, longitude: 17),
        .init(prefix: "HB0", name: "Liechtenstein", latitude: 47.2, longitude: 9.5),
        .init(prefix: "LY", name: "Lithuania", latitude: 55.2, longitude: 23.9),
        .init(prefix: "VK#147", name: "Lord Howe I.", latitude: -31.6, longitude: 159.1),
        .init(prefix: "LX", name: "Luxembourg", latitude: 49.8, longitude: 6.1),
        .init(prefix: "XX9", name: "Macao", latitude: 22.2, longitude: 113.5),
        .init(prefix: "VK7", name: "Macquarie I.", latitude: -54.6, longitude: 158.9),
        .init(prefix: "5R", name: "Madagascar", latitude: -18.8, longitude: 46.9),
        .init(prefix: "CT3", name: "Madeira Is.", latitude: 32.7, longitude: -16.9),
        .init(prefix: "7Q", name: "Malawi", latitude: -13.3, longitude: 34.3),
        .init(prefix: "8Q", name: "Maldives", latitude: 3.2, longitude: 73.2),
        .init(prefix: "TZ", name: "Mali", latitude: 17.6, longitude: -4),
        .init(prefix: "HK0", name: "Malpelo I.", latitude: 4, longitude: -81.6),
        .init(prefix: "9H", name: "Malta", latitude: 35.9, longitude: 14.4),
        .init(prefix: "KH0", name: "Mariana Is.", latitude: 15.2, longitude: 145.8),
        .init(prefix: "OJ0", name: "Market Reef", latitude: 60.3, longitude: 19.1),
        .init(prefix: "FO#509", name: "Marquesas Is.", latitude: -9, longitude: -139.5),
        .init(prefix: "V7", name: "Marshall Is.", latitude: 7.1, longitude: 171.2),
        .init(prefix: "FM", name: "Martinique", latitude: 14.6, longitude: -61),
        .init(prefix: "5T", name: "Mauritania", latitude: 20.3, longitude: -9.5),
        .init(prefix: "3B8", name: "Mauritius", latitude: -20.3, longitude: 57.6),
        .init(prefix: "FH", name: "Mayotte", latitude: -12.8, longitude: 45.2),
        .init(prefix: "VK9#171", name: "Mellish Reef", latitude: -17.4, longitude: 155.9),
        .init(prefix: "XA", name: "Mexico", latitude: 23.6, longitude: -102.5),
        .init(prefix: "V6", name: "Micronesia", latitude: 6.9, longitude: 158.2),
        .init(prefix: "KH4", name: "Midway I.", latitude: 28.2, longitude: -177.4),
        .init(prefix: "JD1", name: "Minami Torishima", latitude: 24.3, longitude: 154),
        .init(prefix: "ER", name: "Moldova (Republic of)", latitude: 47.4, longitude: 28.4),
        .init(prefix: "3A", name: "Monaco", latitude: 43.7, longitude: 7.4),
        .init(prefix: "JT", name: "Mongolia", latitude: 46.9, longitude: 103.8),
        .init(prefix: "4O", name: "Montenegro", latitude: 42.7, longitude: 19.4),
        .init(prefix: "VP2M", name: "Montserrat", latitude: 16.7, longitude: -62.2),
        .init(prefix: "CN", name: "Morocco (Kingdom of)", latitude: 31.8, longitude: -7.1),
        .init(prefix: "SV/A", name: "Mount Athos", latitude: 40.2, longitude: 24.3),
        .init(prefix: "C8", name: "Mozambique", latitude: -18.7, longitude: 35.5),
        .init(prefix: "XY", name: "Myanmar", latitude: 21.9, longitude: 95.9),
        .init(prefix: "V5", name: "Namibia", latitude: -22.6, longitude: 17.1),
        .init(prefix: "C2", name: "Nauru", latitude: -0.5, longitude: 166.9),
        .init(prefix: "KP1", name: "Navassa I.", latitude: 18.4, longitude: -75),
        .init(prefix: "9N", name: "Nepal", latitude: 28.4, longitude: 84.1),
        .init(prefix: "PA", name: "Netherlands", latitude: 52.1, longitude: 5.3),
        .init(prefix: "FK#162", name: "New Caledonia", latitude: -21.3, longitude: 165.5),
        .init(prefix: "ZK", name: "New Zealand", latitude: -40.9, longitude: 174.9),
        .init(prefix: "ZL9", name: "New Zealand Subantarctic Islands", latitude: -51, longitude: 166),
        .init(prefix: "YN", name: "Nicaragua", latitude: 12.9, longitude: -85.2),
        .init(prefix: "5U", name: "Niger", latitude: 17.6, longitude: 8.1),
        .init(prefix: "5N", name: "Nigeria", latitude: 9.1, longitude: 8.7),
        .init(prefix: "E6", name: "Niue", latitude: -19.1, longitude: -169.9),
        .init(prefix: "VK9#189", name: "Norfolk I.", latitude: -29, longitude: 168),
        .init(prefix: "E5", name: "North Cook Is.", latitude: -10.1, longitude: -161.1),
        .init(prefix: "Z3", name: "North Macedonia (Republic of)", latitude: 41.6, longitude: 21.7),
        .init(prefix: "GI", name: "Northern Ireland", latitude: 54.6, longitude: -6.7),
        .init(prefix: "LA", name: "Norway", latitude: 64, longitude: 11),
        .init(prefix: "JD1#192", name: "Ogasawara", latitude: 27.1, longitude: 142.2),
        .init(prefix: "A4", name: "Oman", latitude: 21.5, longitude: 55.9),
        .init(prefix: "AP", name: "Pakistan (Islamic Rep of)", latitude: 30.4, longitude: 69.3),
        .init(prefix: "T8", name: "Palau", latitude: 7.5, longitude: 134.6),
        .init(prefix: "E4", name: "Palestine", latitude: 31.9, longitude: 35.2),
        .init(prefix: "KH5", name: "Palmyra & Jarvis Is.", latitude: 5.9, longitude: -162.1),
        .init(prefix: "HO", name: "Panama", latitude: 8.5, longitude: -80.1),
        .init(prefix: "P2", name: "Papua New Guinea", latitude: -6.3, longitude: 143.9),
        .init(prefix: "ZP", name: "Paraguay", latitude: -23.4, longitude: -58.4),
        .init(prefix: "OA", name: "Peru", latitude: -9.2, longitude: -75),
        .init(prefix: "3Y#199", name: "Peter 1 I.", latitude: -68.8, longitude: -90.6),
        .init(prefix: "DU", name: "Philippines", latitude: 12.9, longitude: 121.8),
        .init(prefix: "VP6#172", name: "Pitcairn I.", latitude: -25.1, longitude: -130.1),
        .init(prefix: "SN", name: "Poland", latitude: 51.9, longitude: 19.1),
        .init(prefix: "CQ", name: "Portugal", latitude: 39.4, longitude: -8.2),
        .init(prefix: "BV9P", name: "Pratas I.", latitude: 20.7, longitude: 116.7),
        .init(prefix: "ZS8", name: "Prince Edward & Marion Is.", latitude: -46.6, longitude: 37.9),
        .init(prefix: "KP3", name: "Puerto Rico", latitude: 18.2, longitude: -66.4),
        .init(prefix: "A7", name: "Qatar", latitude: 25.3, longitude: 51.2),
        .init(prefix: "Z6", name: "Republic of Kosovo", latitude: 42.6, longitude: 20.9),
        .init(prefix: "TA", name: "Republic of Turkiye", latitude: 39, longitude: 35.2),
        .init(prefix: "TN", name: "Republic of the Congo", latitude: -0.2, longitude: 15.8),
        .init(prefix: "FR", name: "Reunion I.", latitude: -21.1, longitude: 55.5),
        .init(prefix: "XA4", name: "Revillagigedo", latitude: 18.8, longitude: -111),
        .init(prefix: "3B9", name: "Rodrigues I.", latitude: -19.7, longitude: 63.4),
        .init(prefix: "YO", name: "Romania", latitude: 45.9, longitude: 25),
        .init(prefix: "3D2#460", name: "Rotuma I.", latitude: -12.5, longitude: 177.1),
        .init(prefix: "9X", name: "Rwanda", latitude: -1.9, longitude: 29.9),
        .init(prefix: "PJ5", name: "Saba & St. Eustatius", latitude: 17.5, longitude: -63.2),
        .init(prefix: "CY0", name: "Sable I.", latitude: 43.9, longitude: -59.9),
        .init(prefix: "FJ", name: "Saint Barthelemy", latitude: 17.9, longitude: -62.8),
        .init(prefix: "FS", name: "Saint Martin", latitude: 18.1, longitude: -63.1),
        .init(prefix: "5W", name: "Samoa", latitude: -13.8, longitude: -172.1),
        .init(prefix: "HK0#216", name: "San Andres & Providencia", latitude: 12.6, longitude: -81.7),
        .init(prefix: "CE0#217", name: "San Felix & San Ambrosio", latitude: -26.3, longitude: -80.1),
        .init(prefix: "T7", name: "San Marino", latitude: 43.9, longitude: 12.5),
        .init(prefix: "S9", name: "Sao Tome & Principe", latitude: 0.2, longitude: 6.6),
        .init(prefix: "IS0", name: "Sardinia", latitude: 40, longitude: 9),
        .init(prefix: "HZ", name: "Saudi Arabia", latitude: 23.9, longitude: 45.1),
        .init(prefix: "BS7", name: "Scarborough Reef", latitude: 15.1, longitude: 117.8),
        .init(prefix: "GM", name: "Scotland", latitude: 56.5, longitude: -4.2),
        .init(prefix: "6V", name: "Senegal", latitude: 14.5, longitude: -14.5),
        .init(prefix: "YT", name: "Serbia", latitude: 44, longitude: 21),
        .init(prefix: "S7", name: "Seychelles", latitude: -4.7, longitude: 55.5),
        .init(prefix: "9L", name: "Sierra Leone", latitude: 8.5, longitude: -11.8),
        .init(prefix: "9V", name: "Singapore (Republic of)", latitude: 1.35, longitude: 103.8),
        .init(prefix: "PJ7", name: "Sint Maarten", latitude: 18, longitude: -63.1),
        .init(prefix: "OM", name: "Slovak Republic", latitude: 48.7, longitude: 19.7),
        .init(prefix: "S5", name: "Slovenia", latitude: 46.1, longitude: 14.8),
        .init(prefix: "H4", name: "Solomon Is.", latitude: -9.6, longitude: 160.2),
        .init(prefix: "T5", name: "Somalia", latitude: 5.2, longitude: 46.2),
        .init(prefix: "ZR", name: "South Africa", latitude: -30.6, longitude: 22.9),
        .init(prefix: "E5#234", name: "South Cook Is.", latitude: -21.2, longitude: -159.8),
        .init(prefix: "VP0", name: "South Georgia I.", latitude: -54.3, longitude: -36.7),
        .init(prefix: "VP0#238", name: "South Orkney Is.", latitude: -60.6, longitude: -45.6),
        .init(prefix: "VP0#240", name: "South Sandwich Is.", latitude: -57.8, longitude: -26.5),
        .init(prefix: "VP0#241", name: "South Shetland Is.", latitude: -62, longitude: -58),
        .init(prefix: "Z8", name: "South Sudan (Republic of)", latitude: 6.9, longitude: 31.3),
        .init(prefix: "1A", name: "Sovereign Military Order of Malta", latitude: 41.9, longitude: 12.5),
        .init(prefix: "EA", name: "Spain", latitude: 40.2, longitude: -3.6),
        .init(prefix: "E247", name: "Spratly Is.", latitude: 8.6, longitude: 111.9),
        .init(prefix: "4P", name: "Sri Lanka", latitude: 7.9, longitude: 80.7),
        .init(prefix: "ZD7", name: "St. Helena", latitude: -15.9, longitude: -5.7),
        .init(prefix: "V4", name: "St. Kitts & Nevis", latitude: 17.3, longitude: -62.7),
        .init(prefix: "J6", name: "St. Lucia", latitude: 13.9, longitude: -61),
        .init(prefix: "CY9", name: "St. Paul I.", latitude: 47.2, longitude: -60.1),
        .init(prefix: "PP0#253", name: "St. Peter & St. Paul Rocks", latitude: 0.9, longitude: -29.3),
        .init(prefix: "FP", name: "St. Pierre & Miquelon", latitude: 46.8, longitude: -56.2),
        .init(prefix: "J8", name: "St. Vincent", latitude: 13.2, longitude: -61.2),
        .init(prefix: "ST", name: "Sudan", latitude: 12.9, longitude: 30.2),
        .init(prefix: "PZ", name: "Suriname", latitude: 4, longitude: -56),
        .init(prefix: "JW", name: "Svalbard", latitude: 78.2, longitude: 15.6),
        .init(prefix: "KH8#515", name: "Swains I.", latitude: -11.1, longitude: -171.1),
        .init(prefix: "SA", name: "Sweden", latitude: 62, longitude: 15),
        .init(prefix: "HB", name: "Switzerland", latitude: 46.8, longitude: 8.2),
        .init(prefix: "YK", name: "Syrian Arab Republic", latitude: 35, longitude: 38.5),
        .init(prefix: "BU", name: "Taiwan", latitude: 23.7, longitude: 121),
        .init(prefix: "EY", name: "Tajikistan", latitude: 38.9, longitude: 71.3),
        .init(prefix: "5H", name: "Tanzania (United Republic of)", latitude: -6.4, longitude: 34.9),
        .init(prefix: "H40", name: "Temotu Province", latitude: -10.7, longitude: 166),
        .init(prefix: "HS", name: "Thailand", latitude: 15.1, longitude: 101),
        .init(prefix: "4W", name: "Timor-Leste", latitude: -8.8, longitude: 125.7),
        .init(prefix: "5V", name: "Togo", latitude: 8.6, longitude: 0.8),
        .init(prefix: "ZK3", name: "Tokelau Is.", latitude: -9.2, longitude: -171.8),
        .init(prefix: "A3", name: "Tonga", latitude: -21.2, longitude: -175.2),
        .init(prefix: "PP0#273", name: "Trindade & Martim Vaz Is.", latitude: -20.5, longitude: -29.3),
        .init(prefix: "9Y", name: "Trinidad & Tobago", latitude: 10.5, longitude: -61.3),
        .init(prefix: "ZD9", name: "Tristan da Cunha & Gough I.", latitude: -37.1, longitude: -12.3),
        .init(prefix: "FT/T", name: "Tromelin I.", latitude: -15.9, longitude: 54.5),
        .init(prefix: "3V", name: "Tunisia", latitude: 34, longitude: 9.6),
        .init(prefix: "EZ", name: "Turkmenistan", latitude: 38.9, longitude: 59.6),
        .init(prefix: "VP5", name: "Turks & Caicos Is.", latitude: 21.8, longitude: -71.8),
        .init(prefix: "T2", name: "Tuvalu", latitude: -7.5, longitude: 178.7),
        .init(prefix: "ZC4", name: "UK Sovereign Base Areas on Cyprus", latitude: 34.9, longitude: 33.7),
        .init(prefix: "5X", name: "Uganda", latitude: 1.4, longitude: 32.3),
        .init(prefix: "UR", name: "Ukraine", latitude: 48.4, longitude: 31.2),
        .init(prefix: "A6", name: "United Arab Emirates", latitude: 23.4, longitude: 53.8),
        .init(prefix: "G", name: "United Kingdom of Great Britain", latitude: 54, longitude: -2.5),
        .init(prefix: "4U_UN", name: "United Nations HQ", latitude: 40.7, longitude: -74),
        .init(prefix: "K", name: "United States of America", latitude: 39, longitude: -98),
        .init(prefix: "CV", name: "Uruguay", latitude: -32.5, longitude: -55.8),
        .init(prefix: "UJ", name: "Uzbekistan", latitude: 41.4, longitude: 64.6),
        .init(prefix: "YJ", name: "Vanuatu", latitude: -15.4, longitude: 166.9),
        .init(prefix: "HV", name: "Vatican", latitude: 41.9, longitude: 12.45),
        .init(prefix: "YV", name: "Venezuela", latitude: 6.4, longitude: -66.6),
        .init(prefix: "3W", name: "Viet Nam", latitude: 16, longitude: 106),
        .init(prefix: "KP2", name: "Virgin Is.", latitude: 18.3, longitude: -64.9),
        .init(prefix: "T30", name: "W. Kiribati (Gilbert Is. )", latitude: 1.4, longitude: 173.0),
        .init(prefix: "KH9", name: "Wake I.", latitude: 19.3, longitude: 166.6),
        .init(prefix: "GW", name: "Wales", latitude: 52.3, longitude: -3.8),
        .init(prefix: "FW", name: "Wallis & Futuna Is.", latitude: -13.3, longitude: -176.2),
        .init(prefix: "9M2", name: "West Malaysia", latitude: 4.2, longitude: 102),
        .init(prefix: "S0", name: "Western Sahara", latitude: 24.2, longitude: -12.9),
        .init(prefix: "VK9#303", name: "Willis I.", latitude: -16.3, longitude: 150),
        .init(prefix: "7O", name: "Yemen", latitude: 15.6, longitude: 48),
        .init(prefix: "9I", name: "Zambia", latitude: -13.1, longitude: 27.8),
        .init(prefix: "Z2", name: "Zimbabwe", latitude: -19, longitude: 29.9),
    ]

    static func search(_ query: String, limit: Int = 20) -> [DXCCEntity] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Array(entities.prefix(limit)) }
        let u = q.uppercased()
        return entities.filter { $0.prefix.uppercased() == u || $0.prefix.uppercased().contains(u) || $0.name.uppercased().contains(u) }
            .sorted { a, b in
                let ae = a.prefix.uppercased() == u, be = b.prefix.uppercased() == u
                if ae != be { return ae }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }.prefix(limit).map { $0 }
    }

    static func entity(named name: String) -> DXCCEntity? {
        entities.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func workable(subLatitude: Double, subLongitude: Double, altitudeKm: Double) -> [DXCCEntity] {
        let radius = FeatureEngine.footprintRadiusDegrees(altitudeKm: altitudeKm)
        guard radius > 0 else { return [] }
        return entities.filter { FeatureEngine.angularSeparationDegrees(subLatitude, subLongitude, $0.latitude, $0.longitude) <= radius }
    }
}


/// Reverse-geocoded political context for a position: the DXCC entity plus the
/// primary and secondary administrative subdivisions (e.g. state and county).
/// Used to annotate the operator's station when following the current location.
struct GeoLocationEntity: Sendable, Equatable {
    var dxccName: String?
    var dxccPrefix: String?
    var country: String?
    var isoCountryCode: String?
    var primarySubdivision: String?    // CLPlacemark.administrativeArea
    var secondarySubdivision: String?  // CLPlacemark.subAdministrativeArea

    /// "K · United States of America" (prefix + name) or just the name.
    var dxccLabel: String? {
        guard let dxccName else { return nil }
        if let dxccPrefix, !dxccPrefix.isEmpty { return "\(dxccPrefix) · \(dxccName)" }
        return dxccName
    }

    var hasAnything: Bool {
        dxccName != nil || primarySubdivision != nil || secondarySubdivision != nil
    }
}

enum GeoEntityLookup {
    /// Reverse-geocode a coordinate into a DXCC entity and administrative
    /// subdivisions. Returns nil on failure (no network, throttled, or no match).
    static func lookup(latitude: Double, longitude: Double) async -> GeoLocationEntity? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let placemarks: [CLPlacemark] = await withCheckedContinuation { continuation in
            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                continuation.resume(returning: placemarks ?? [])
            }
        }
        guard let placemark = placemarks.first else { return nil }
        let iso = placemark.isoCountryCode?.uppercased()
        let dxcc = dxccEntity(iso: iso, administrativeArea: placemark.administrativeArea)
        let primary = adifPrimary(iso: iso, administrativeArea: placemark.administrativeArea)
        let secondary: String?
        if iso == "US" {
            secondary = usSecondary(state: primary,
                                    subAdmin: placemark.subAdministrativeArea,
                                    locality: placemark.locality,
                                    subLocality: placemark.subLocality,
                                    name: placemark.name)
        } else {
            secondary = placemark.subAdministrativeArea
        }
        let entity = GeoLocationEntity(
            dxccName: dxcc?.name ?? placemark.country,
            dxccPrefix: dxcc?.prefix,
            country: placemark.country,
            isoCountryCode: iso,
            primarySubdivision: primary,
            secondarySubdivision: secondary
        )
        return entity.hasAnything ? entity : nil
    }

    /// The legacy (pre-2024) Connecticut county for a town or village name, which is
    /// the secondary subdivision LoTW/TQSL still expects. Returns nil for an unknown
    /// place so the caller can fall back to the normalized planning-region name.
    static func ctLegacyCounty(town: String?) -> String? {
        guard let raw = town?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return ctTownToCounty[raw]
    }

    /// Resolve the LoTW/TQSL secondary administrative subdivision for a US position.
    /// Ordering matters: a county designator ("… County/Parish/Borough") is treated
    /// as the county (so a same-named independent city can't hijack it); only when no
    /// county designator is present do we resolve an independent city. Handles the
    /// four US locales whose secondary subdivision isn't a plain county — Connecticut
    /// (planning regions → legacy county) and the independent cities of Virginia,
    /// Maryland (Baltimore), Missouri (St. Louis) and Nevada (Carson City).
    static func usSecondary(state: String?, subAdmin: String?, locality: String?, subLocality: String?, name: String?) -> String? {
        // Connecticut: Core Location returns a planning region; map the town to its
        // legacy county.
        if state == "CT" {
            if let county = ctLegacyCounty(town: locality) ?? ctLegacyCounty(town: subLocality) { return county }
        }
        // County / parish / borough context → the normalized bare LoTW name.
        if let sub = subAdmin, hasCountyDesignator(sub) {
            return adifSecondary(iso: "US", subAdministrativeArea: sub)
        }
        // No county designator: this is independent-city territory (or Core Location
        // simply didn't supply a county). Match the city against the state's
        // independent-city roster, checking the most specific fields first.
        if let state {
            for place in [locality, subAdmin, name].compactMap({ $0 }) {
                if let lotw = independentCityName(state: state, place: place) { return lotw }
            }
        }
        // Fallback: normalize whatever subdivision we have (e.g. strip "Planning
        // Region" for an unrecognized CT place).
        return subAdmin.map { adifSecondary(iso: "US", subAdministrativeArea: $0) } ?? nil
    }

    /// True when Core Location's subdivision string carries a county-equivalent
    /// government designator, i.e. it denotes a county rather than an independent city.
    static func hasCountyDesignator(_ s: String) -> Bool {
        let l = s.lowercased()
        return [" county", " parish", " borough", " census area", " municipality", " city and borough"]
            .contains { l.hasSuffix($0) }
    }

    /// The LoTW/TQSL name for an independent city in a given state, or nil if the
    /// place isn't one. Colliding names carry a "City" suffix to distinguish them
    /// from the same-named county (e.g. "Richmond City" vs the county "Richmond").
    static func independentCityName(state: String, place: String) -> String? {
        guard let table = independentCities[state] else { return nil }
        let p = place.lowercased().trimmingCharacters(in: .whitespaces)
        let stripped = p.hasSuffix(" city") ? String(p.dropLast(5)).trimmingCharacters(in: .whitespaces) : p
        return table[p] ?? table[stripped]
    }

    private static let independentCities: [String: [String: String]] = [
        "VA": vaIndependentCities,
        "MD": ["baltimore": "Baltimore City"],
        "MO": ["st. louis": "St. Louis City", "saint louis": "St. Louis City"],
        "NV": ["carson city": "Carson City"]
    ]

    /// Virginia's 38 independent cities keyed by their bare (lowercased) name. Four
    /// share a name with a Virginia county and take the "City" suffix in LoTW/TQSL.
    private static let vaIndependentCities: [String: String] = {
        let bare = ["Alexandria", "Bristol", "Buena Vista", "Charlottesville", "Chesapeake",
                    "Colonial Heights", "Covington", "Danville", "Emporia", "Falls Church",
                    "Fredericksburg", "Galax", "Hampton", "Harrisonburg", "Hopewell", "Lexington",
                    "Lynchburg", "Manassas", "Manassas Park", "Martinsville", "Newport News",
                    "Norfolk", "Norton", "Petersburg", "Poquoson", "Portsmouth", "Radford",
                    "Salem", "Staunton", "Suffolk", "Virginia Beach", "Waynesboro", "Williamsburg",
                    "Winchester"]
        let collide = ["Fairfax": "Fairfax City", "Franklin": "Franklin City",
                       "Richmond": "Richmond City", "Roanoke": "Roanoke City"]
        var out: [String: String] = [:]
        for c in bare { out[c.lowercased()] = c }
        for (k, v) in collide { out[k.lowercased()] = v }
        return out
    }()

    /// Normalize Core Location's `administrativeArea` to the ADIF Primary
    /// Administrative Subdivision. For the US that is the two-letter STATE code
    /// (Core Location sometimes yields the full name); other countries pass through.
    static func adifPrimary(iso: String?, administrativeArea: String?) -> String? {
        guard let raw = administrativeArea?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        guard iso == "US" else { return raw }
        // Already a valid 2-letter code?
        let upper = raw.uppercased()
        if upper.count == 2, usStateCodes.contains(upper) { return upper }
        // Full state name → code.
        if let code = usStateNameToCode[raw.lowercased()] { return code }
        return raw
    }

    /// Normalize Core Location's `subAdministrativeArea` to the ADIF Secondary
    /// Administrative Subdivision name. For the US this strips the government
    /// designators Core Location appends (County, Parish, Borough, Census Area,
    /// Municipality) and the Connecticut "Planning Region" suffix — which maps a
    /// planning region onto its ADIF secondary-subdivision-alt name (e.g. "Capitol
    /// Planning Region" → "Capitol") and boroughs/census areas onto the ADIF Alaska
    /// names (e.g. "Fairbanks North Star Borough" → "Fairbanks North Star").
    static func adifSecondary(iso: String?, subAdministrativeArea: String?) -> String? {
        guard var s = subAdministrativeArea?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        guard iso == "US" else { return s }
        // Alaska's Anchorage/Juneau come through with a leading designator.
        for prefix in ["Municipality of ", "City and Borough of "] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        for suffix in [" Planning Region", " City and Borough", " Census Area",
                       " Borough", " Parish", " Municipality", " County"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
            break
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static let usStateNameToCode: [String: String] = [
        "alabama": "AL", "alaska": "AK", "arizona": "AZ", "arkansas": "AR", "california": "CA",
        "colorado": "CO", "connecticut": "CT", "delaware": "DE", "district of columbia": "DC",
        "florida": "FL", "georgia": "GA", "hawaii": "HI", "idaho": "ID", "illinois": "IL",
        "indiana": "IN", "iowa": "IA", "kansas": "KS", "kentucky": "KY", "louisiana": "LA",
        "maine": "ME", "maryland": "MD", "massachusetts": "MA", "michigan": "MI", "minnesota": "MN",
        "mississippi": "MS", "missouri": "MO", "montana": "MT", "nebraska": "NE", "nevada": "NV",
        "new hampshire": "NH", "new jersey": "NJ", "new mexico": "NM", "new york": "NY",
        "north carolina": "NC", "north dakota": "ND", "ohio": "OH", "oklahoma": "OK", "oregon": "OR",
        "pennsylvania": "PA", "rhode island": "RI", "south carolina": "SC", "south dakota": "SD",
        "tennessee": "TN", "texas": "TX", "utah": "UT", "vermont": "VT", "virginia": "VA",
        "washington": "WA", "west virginia": "WV", "wisconsin": "WI", "wyoming": "WY"
    ]
    private static let usStateCodes: Set<String> = Set(usStateNameToCode.values)

    /// Every Connecticut town (and common village/CDP name Core Location may return
    /// as the locality) mapped to its legacy county — the value LoTW/TQSL expects.
    private static let ctTownToCounty: [String: String] = {
        let byCounty: [String: [String]] = [
            "Fairfield": ["bethel", "bridgeport", "brookfield", "danbury", "darien", "easton",
                          "fairfield", "greenwich", "monroe", "new canaan", "new fairfield",
                          "newtown", "norwalk", "redding", "ridgefield", "shelton", "sherman",
                          "stamford", "stratford", "trumbull", "weston", "westport", "wilton",
                          // common villages/CDPs
                          "cos cob", "riverside", "old greenwich", "glenville", "georgetown", "nichols"],
            "Hartford": ["avon", "berlin", "bloomfield", "bristol", "burlington", "canton",
                         "east granby", "east hartford", "east windsor", "enfield", "farmington",
                         "glastonbury", "granby", "hartford", "hartland", "manchester", "marlborough",
                         "new britain", "newington", "plainville", "rocky hill", "simsbury",
                         "southington", "south windsor", "suffield", "west hartford", "wethersfield",
                         "windsor", "windsor locks",
                         "collinsville", "tariffville", "weatogue", "unionville", "kensington", "broad brook"],
            "Litchfield": ["barkhamsted", "bethlehem", "bridgewater", "canaan", "colebrook", "cornwall",
                           "goshen", "harwinton", "kent", "litchfield", "morris", "new hartford",
                           "new milford", "norfolk", "north canaan", "plymouth", "roxbury", "salisbury",
                           "sharon", "thomaston", "torrington", "warren", "washington", "watertown",
                           "winchester", "woodbury",
                           "oakville", "terryville", "winsted"],
            "Middlesex": ["chester", "clinton", "cromwell", "deep river", "durham", "east haddam",
                          "east hampton", "essex", "haddam", "killingworth", "middlefield", "middletown",
                          "old saybrook", "portland", "westbrook", "moodus", "ivoryton"],
            "New Haven": ["ansonia", "beacon falls", "bethany", "branford", "cheshire", "derby",
                          "east haven", "guilford", "hamden", "madison", "meriden", "middlebury",
                          "milford", "naugatuck", "new haven", "north branford", "north haven",
                          "orange", "oxford", "prospect", "seymour", "southbury", "wallingford",
                          "waterbury", "west haven", "wolcott", "woodbridge",
                          "stony creek", "yalesville"],
            "New London": ["bozrah", "colchester", "east lyme", "franklin", "griswold", "groton",
                           "lebanon", "ledyard", "lisbon", "lyme", "montville", "new london",
                           "north stonington", "norwich", "old lyme", "preston", "salem", "sprague",
                           "stonington", "voluntown", "waterford",
                           "mystic", "pawcatuck", "poquonock bridge", "jewett city", "gales ferry",
                           "quaker hill", "baltic", "niantic", "uncasville", "noank", "groton long point"],
            "Tolland": ["andover", "bolton", "columbia", "coventry", "ellington", "hebron", "mansfield",
                        "somers", "stafford", "tolland", "union", "vernon", "willington",
                        "storrs", "storrs mansfield", "rockville", "stafford springs"],
            "Windham": ["ashford", "brooklyn", "canterbury", "chaplin", "eastford", "hampton",
                        "killingly", "plainfield", "pomfret", "putnam", "scotland", "sterling",
                        "thompson", "windham", "woodstock",
                        "moosup", "central village", "wauregan", "danielson", "willimantic"]
        ]
        var out: [String: String] = [:]
        for (county, towns) in byCounty { for town in towns { out[town] = county } }
        return out
    }()

    /// Map an ISO 3166-1 alpha-2 country/territory code to the ARRL DXCC entity.
    /// A handful of DXCC entities share one ISO code (the US mainland vs Alaska and
    /// Hawaii; the UK's four home nations), so those are split on the primary
    /// administrative area. Unmapped codes fall back to the geocoded country name.
    static func dxccEntity(iso: String?, administrativeArea: String?) -> (prefix: String, name: String)? {
        guard let iso else { return nil }
        let admin = (administrativeArea ?? "").lowercased()

        if iso == "US" {
            // Core Location usually yields the 2-letter state code ("AK"/"HI"), but
            // may yield the full name; accept both so Alaska/Hawaii resolve to their
            // own DXCC entities rather than the contiguous US.
            if admin == "ak" || admin.contains("alaska") { return ("KL", "Alaska") }
            if admin == "hi" || admin.contains("hawaii") { return ("KH6", "Hawaii") }
            return ("K", "United States of America")
        }
        if iso == "GB" {
            if admin.contains("scotland") { return ("GM", "Scotland") }
            if admin.contains("wales") { return ("GW", "Wales") }
            if admin.contains("northern ireland") { return ("GI", "Northern Ireland") }
            return ("G", "England")
        }
        return isoToDXCC[iso]
    }

    /// ISO 3166-1 alpha-2 → (DXCC prefix, ARRL entity name). US/GB are handled
    /// above; territories with their own ISO code appear here directly.
    private static let isoToDXCC: [String: (prefix: String, name: String)] = [
        "AF": ("YA", "Afghanistan"), "AX": ("OH0", "Aland Is."), "AL": ("ZA", "Albania"),
        "DZ": ("7X", "Algeria"), "AS": ("KH8", "American Samoa"), "AD": ("C3", "Andorra"),
        "AO": ("D2", "Angola"), "AI": ("VP2E", "Anguilla"), "AQ": ("CE9", "Antarctica"),
        "AG": ("V2", "Antigua & Barbuda"), "AR": ("LU", "Argentina"), "AM": ("EK", "Armenia"),
        "AW": ("P4", "Aruba"), "AU": ("VK", "Australia"), "AT": ("OE", "Austria"),
        "AZ": ("4J", "Azerbaijan"), "BS": ("C6", "Bahamas"), "BH": ("A9", "Bahrain"),
        "BD": ("S2", "Bangladesh"), "BB": ("8P", "Barbados"), "BY": ("EU", "Belarus"),
        "BE": ("ON", "Belgium"), "BZ": ("V3", "Belize"), "BJ": ("TY", "Benin"),
        "BM": ("VP9", "Bermuda"), "BT": ("A5", "Bhutan"), "BO": ("CP", "Bolivia"),
        "BA": ("E7", "Bosnia-Herzegovina"), "BW": ("A2", "Botswana"), "BR": ("PY", "Brazil"),
        "BN": ("V8", "Brunei Darussalam"), "BG": ("LZ", "Bulgaria"), "BF": ("XT", "Burkina Faso"),
        "BI": ("9U", "Burundi"), "KH": ("XU", "Cambodia"), "CM": ("TJ", "Cameroon"),
        "CA": ("VE", "Canada"), "CV": ("D4", "Cape Verde"), "KY": ("ZF", "Cayman Is."),
        "CF": ("TL", "Central Africa"), "TD": ("TT", "Chad"), "CL": ("CE", "Chile"),
        "CN": ("BY", "China"), "CO": ("HK", "Colombia"), "KM": ("D6", "Comoros"),
        "CG": ("TN", "Congo (Republic of the)"), "CD": ("9Q", "Dem. Rep. of the Congo"),
        "CK": ("E5", "South Cook Is."), "CR": ("TI", "Costa Rica"), "CI": ("TU", "Cote d'Ivoire"),
        "HR": ("9A", "Croatia"), "CU": ("CO", "Cuba"), "CW": ("PJ2", "Curacao"),
        "CY": ("5B", "Cyprus"), "CZ": ("OK", "Czech Republic"), "DK": ("OZ", "Denmark"),
        "DJ": ("J2", "Djibouti"), "DM": ("J7", "Dominica"), "DO": ("HI", "Dominican Republic"),
        "EC": ("HC", "Ecuador"), "EG": ("SU", "Egypt"), "SV": ("YS", "El Salvador"),
        "GQ": ("3C", "Equatorial Guinea"), "ER": ("E3", "Eritrea"), "EE": ("ES", "Estonia"),
        "SZ": ("3DA", "Kingdom of Eswatini"), "ET": ("ET", "Ethiopia"), "FK": ("VP8", "Falkland Is."),
        "FO": ("OY", "Faroe Is."), "FJ": ("3D2", "Fiji"), "FI": ("OH", "Finland"),
        "FR": ("F", "France"), "GF": ("FY", "French Guiana"), "PF": ("FO", "French Polynesia"),
        "GA": ("TR", "Gabon"), "GM": ("C5", "The Gambia"), "GE": ("4L", "Georgia"),
        "DE": ("DL", "Germany (Federal Rep of)"), "GH": ("9G", "Ghana"), "GI": ("ZB", "Gibraltar"),
        "GR": ("SV", "Greece"), "GL": ("OX", "Greenland"), "GD": ("J3", "Grenada"),
        "GP": ("FG", "Guadeloupe"), "GU": ("KH2", "Guam"), "GT": ("TG", "Guatemala"),
        "GG": ("GU", "Guernsey"), "GN": ("3X", "Guinea"), "GW": ("J5", "Guinea-Bissau"),
        "GY": ("8R", "Guyana"), "HT": ("HH", "Haiti"), "HN": ("HR", "Honduras"),
        "HK": ("VR", "Hong Kong"), "HU": ("HA", "Hungary"), "IS": ("TF", "Iceland"),
        "IN": ("VU", "India"), "ID": ("YB", "Indonesia"), "IR": ("EP", "Iran"),
        "IQ": ("YI", "Iraq"), "IE": ("EI", "Ireland"), "IM": ("GD", "Isle of Man"),
        "IL": ("4X", "Israel"), "IT": ("I", "Italy"), "JM": ("6Y", "Jamaica"),
        "JP": ("JA", "Japan"), "JE": ("GJ", "Jersey"), "JO": ("JY", "Jordan"),
        "KZ": ("UN", "Kazakhstan"), "KE": ("5Z", "Kenya"), "KI": ("T30", "Western Kiribati"),
        "KP": ("P5", "Dem. People's Rep. of Korea"), "KR": ("HL", "Republic of Korea"),
        "KW": ("9K", "Kuwait"), "KG": ("EX", "Kyrgyzstan"), "LA": ("XW", "Laos"),
        "LV": ("YL", "Latvia"), "LB": ("OD", "Lebanon"), "LS": ("7P", "Lesotho"),
        "LR": ("EL", "Liberia"), "LY": ("5A", "Libya"), "LI": ("HB0", "Liechtenstein"),
        "LT": ("LY", "Lithuania"), "LU": ("LX", "Luxembourg"), "MO": ("XX9", "Macao"),
        "MK": ("Z3", "North Macedonia"), "MG": ("5R", "Madagascar"), "MW": ("7Q", "Malawi"),
        "MY": ("9M", "West Malaysia"), "MV": ("8Q", "Maldives"), "ML": ("TZ", "Mali"),
        "MT": ("9H", "Malta"), "MH": ("V7", "Marshall Is."), "MQ": ("FM", "Martinique"),
        "MR": ("5T", "Mauritania"), "MU": ("3B8", "Mauritius"), "MX": ("XE", "Mexico"),
        "FM": ("V6", "Micronesia"), "MD": ("ER", "Moldova"), "MC": ("3A", "Monaco"),
        "MN": ("JT", "Mongolia"), "ME": ("4O", "Montenegro"), "MS": ("VP2M", "Montserrat"),
        "MA": ("CN", "Morocco"), "MZ": ("C9", "Mozambique"), "MM": ("XZ", "Myanmar"),
        "NA": ("V5", "Namibia"), "NR": ("C2", "Nauru"), "NP": ("9N", "Nepal"),
        "NL": ("PA", "Netherlands"), "NC": ("FK", "New Caledonia"), "NZ": ("ZL", "New Zealand"),
        "NI": ("YN", "Nicaragua"), "NE": ("5U", "Niger"), "NG": ("5N", "Nigeria"),
        "NU": ("E6", "Niue"), "NO": ("LA", "Norway"), "OM": ("A4", "Oman"),
        "PK": ("AP", "Pakistan"), "PW": ("T8", "Palau"), "PS": ("E4", "Palestine"),
        "PA": ("HP", "Panama"), "PG": ("P2", "Papua New Guinea"), "PY": ("ZP", "Paraguay"),
        "PE": ("OA", "Peru"), "PH": ("DU", "Philippines"), "PL": ("SP", "Poland"),
        "PT": ("CT", "Portugal"), "PR": ("KP4", "Puerto Rico"), "QA": ("A7", "Qatar"),
        "RE": ("FR", "Reunion I."), "RO": ("YO", "Romania"), "RU": ("UA", "European Russia"),
        "RW": ("9X", "Rwanda"), "WS": ("5W", "Samoa"), "SM": ("T7", "San Marino"),
        "ST": ("S9", "Sao Tome & Principe"), "SA": ("HZ", "Saudi Arabia"), "SN": ("6W", "Senegal"),
        "RS": ("YT", "Serbia"), "SC": ("S7", "Seychelles"), "SL": ("9L", "Sierra Leone"),
        "SG": ("9V", "Singapore"), "SX": ("PJ7", "Sint Maarten"), "SK": ("OM", "Slovak Republic"),
        "SI": ("S5", "Slovenia"), "SB": ("H4", "Solomon Is."), "SO": ("T5", "Somalia"),
        "ZA": ("ZS", "South Africa"), "SS": ("Z8", "South Sudan (Republic of)"), "ES": ("EA", "Spain"),
        "LK": ("4S", "Sri Lanka"), "SD": ("ST", "Sudan"), "SR": ("PZ", "Suriname"),
        "SE": ("SM", "Sweden"), "CH": ("HB", "Switzerland"), "SY": ("YK", "Syria"),
        "TW": ("BV", "Taiwan"), "TJ": ("EY", "Tajikistan"), "TZ": ("5H", "Tanzania"),
        "TH": ("HS", "Thailand"), "TL": ("4W", "Timor-Leste"), "TG": ("5V", "Togo"),
        "TO": ("A3", "Tonga"), "TT": ("9Y", "Trinidad & Tobago"), "TN": ("3V", "Tunisia"),
        "TR": ("TA", "Turkey"), "TM": ("EZ", "Turkmenistan"), "TC": ("VP5", "Turks & Caicos Is."),
        "TV": ("T2", "Tuvalu"), "UG": ("5X", "Uganda"), "UA": ("UR", "Ukraine"),
        "AE": ("A6", "United Arab Emirates"), "UY": ("CX", "Uruguay"), "UZ": ("UK", "Uzbekistan"),
        "VU": ("YJ", "Vanuatu"), "VA": ("HV", "Vatican City"), "VE": ("YV", "Venezuela"),
        "VN": ("3W", "Vietnam"), "VG": ("VP2V", "British Virgin Is."), "VI": ("KP2", "US Virgin Is."),
        "YE": ("7O", "Yemen"), "ZM": ("9J", "Zambia"), "ZW": ("Z2", "Zimbabwe")
    ]
}
