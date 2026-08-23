"""Static value pools for the generators.

Public facts (real vehicle names, real launch sites/pads, approximate public
specs) are used freely. Every company, customer, supplier, and person below is
fictional — the operating conceit is that "Meridian Launch Systems" (MLS) is a
fictional launch-services integrator flying real vehicle types.
"""

# ---------------------------------------------------------------------------
# Vehicles (real vehicle names; approximate public specs)
# ---------------------------------------------------------------------------
# last_flight_year None => still active at the end of the data window.
VEHICLES = [
    {"vehicle_id": "VEH-001", "name": "Falcon 9 Block 5", "vehicle_class": "medium",
     "stages": 2, "reusable": True, "leo_capacity_kg": 22800, "gto_capacity_kg": 8300,
     "height_m": 70.0, "first_flight_year": 2018, "last_flight_year": None},
    {"vehicle_id": "VEH-002", "name": "Falcon Heavy", "vehicle_class": "heavy",
     "stages": 2, "reusable": True, "leo_capacity_kg": 63800, "gto_capacity_kg": 26700,
     "height_m": 70.0, "first_flight_year": 2018, "last_flight_year": None},
    {"vehicle_id": "VEH-003", "name": "Electron", "vehicle_class": "small",
     "stages": 2, "reusable": False, "leo_capacity_kg": 300, "gto_capacity_kg": None,
     "height_m": 18.0, "first_flight_year": 2017, "last_flight_year": None},
    {"vehicle_id": "VEH-004", "name": "Atlas V 541", "vehicle_class": "medium",
     "stages": 2, "reusable": False, "leo_capacity_kg": 17410, "gto_capacity_kg": 8290,
     "height_m": 62.2, "first_flight_year": 2011, "last_flight_year": None},
    {"vehicle_id": "VEH-005", "name": "Vulcan Centaur VC4", "vehicle_class": "medium",
     "stages": 2, "reusable": False, "leo_capacity_kg": 24300, "gto_capacity_kg": 13600,
     "height_m": 61.6, "first_flight_year": 2024, "last_flight_year": None},
    {"vehicle_id": "VEH-006", "name": "Delta IV Heavy", "vehicle_class": "heavy",
     "stages": 2, "reusable": False, "leo_capacity_kg": 28790, "gto_capacity_kg": 14220,
     "height_m": 72.0, "first_flight_year": 2004, "last_flight_year": 2024},
    {"vehicle_id": "VEH-007", "name": "New Glenn", "vehicle_class": "heavy",
     "stages": 2, "reusable": True, "leo_capacity_kg": 45000, "gto_capacity_kg": 13000,
     "height_m": 98.0, "first_flight_year": 2025, "last_flight_year": None},
    {"vehicle_id": "VEH-008", "name": "Antares 330", "vehicle_class": "medium",
     "stages": 2, "reusable": False, "leo_capacity_kg": 10500, "gto_capacity_kg": None,
     "height_m": 42.5, "first_flight_year": 2025, "last_flight_year": None},
    {"vehicle_id": "VEH-009", "name": "Ariane 62", "vehicle_class": "medium",
     "stages": 2, "reusable": False, "leo_capacity_kg": 10350, "gto_capacity_kg": 5000,
     "height_m": 63.0, "first_flight_year": 2024, "last_flight_year": None},
    {"vehicle_id": "VEH-010", "name": "H3-24", "vehicle_class": "medium",
     "stages": 2, "reusable": False, "leo_capacity_kg": 16500, "gto_capacity_kg": 6500,
     "height_m": 63.0, "first_flight_year": 2023, "last_flight_year": None},
    {"vehicle_id": "VEH-011", "name": "Firefly Alpha", "vehicle_class": "small",
     "stages": 2, "reusable": False, "leo_capacity_kg": 1030, "gto_capacity_kg": None,
     "height_m": 29.0, "first_flight_year": 2021, "last_flight_year": None},
    {"vehicle_id": "VEH-012", "name": "Minotaur IV", "vehicle_class": "small",
     "stages": 4, "reusable": False, "leo_capacity_kg": 1735, "gto_capacity_kg": None,
     "height_m": 23.9, "first_flight_year": 2010, "last_flight_year": None},
]

# Relative launch-rate weights per vehicle_id (Falcon 9 / Electron dominant).
VEHICLE_WEIGHTS = {
    "VEH-001": 34, "VEH-002": 4, "VEH-003": 18, "VEH-004": 6, "VEH-005": 7,
    "VEH-006": 2, "VEH-007": 4, "VEH-008": 3, "VEH-009": 7, "VEH-010": 6,
    "VEH-011": 5, "VEH-012": 4,
}

FLEET_GROUPS = {
    "small": "MLS Smallsat Fleet",
    "medium": "MLS Medium Fleet",
    "heavy": "MLS Heavy Fleet",
}

# ---------------------------------------------------------------------------
# Pads (real pads/sites; approximate public coordinates)
# ---------------------------------------------------------------------------
PADS = [
    {"pad_id": "PAD-01", "name": "SLC-40", "site": "Cape Canaveral Space Force Station",
     "country": "USA", "latitude": 28.5620, "longitude": -80.5772,
     "first_used_year": 1965, "status": "active"},
    {"pad_id": "PAD-02", "name": "LC-39A", "site": "Kennedy Space Center",
     "country": "USA", "latitude": 28.6084, "longitude": -80.6043,
     "first_used_year": 1967, "status": "active"},
    {"pad_id": "PAD-03", "name": "SLC-4E", "site": "Vandenberg Space Force Base",
     "country": "USA", "latitude": 34.6320, "longitude": -120.6106,
     "first_used_year": 1962, "status": "active"},
    {"pad_id": "PAD-04", "name": "SLC-41", "site": "Cape Canaveral Space Force Station",
     "country": "USA", "latitude": 28.5834, "longitude": -80.5830,
     "first_used_year": 1965, "status": "active"},
    {"pad_id": "PAD-05", "name": "SLC-37B", "site": "Cape Canaveral Space Force Station",
     "country": "USA", "latitude": 28.5317, "longitude": -80.5646,
     "first_used_year": 1968, "status": "retired"},
    {"pad_id": "PAD-06", "name": "LC-36", "site": "Cape Canaveral Space Force Station",
     "country": "USA", "latitude": 28.4705, "longitude": -80.5430,
     "first_used_year": 1962, "status": "active"},
    {"pad_id": "PAD-07", "name": "LC-1A", "site": "Mahia Peninsula",
     "country": "New Zealand", "latitude": -39.2615, "longitude": 177.8646,
     "first_used_year": 2017, "status": "active"},
    {"pad_id": "PAD-08", "name": "LC-2", "site": "Wallops Island (MARS)",
     "country": "USA", "latitude": 37.8337, "longitude": -75.4881,
     "first_used_year": 2019, "status": "active"},
    {"pad_id": "PAD-09", "name": "ELA-4", "site": "Guiana Space Centre",
     "country": "France", "latitude": 5.2560, "longitude": -52.7780,
     "first_used_year": 2024, "status": "active"},
    {"pad_id": "PAD-10", "name": "SLC-2W", "site": "Vandenberg Space Force Base",
     "country": "USA", "latitude": 34.7556, "longitude": -120.6224,
     "first_used_year": 1966, "status": "active"},
    {"pad_id": "PAD-11", "name": "LA-Y2", "site": "Tanegashima Space Center",
     "country": "Japan", "latitude": 30.4008, "longitude": 130.9754,
     "first_used_year": 2023, "status": "active"},
]

# Which pads each vehicle can fly from.
PAD_COMPAT = {
    "VEH-001": ["PAD-01", "PAD-02", "PAD-03"],
    "VEH-002": ["PAD-02"],
    "VEH-003": ["PAD-07", "PAD-08"],
    "VEH-004": ["PAD-04"],
    "VEH-005": ["PAD-04"],
    "VEH-006": ["PAD-05"],
    "VEH-007": ["PAD-06"],
    "VEH-008": ["PAD-08"],
    "VEH-009": ["PAD-09"],
    "VEH-010": ["PAD-11"],
    "VEH-011": ["PAD-10"],
    "VEH-012": ["PAD-10", "PAD-08"],
}

# Orbits available per vehicle class, with weights.
ORBITS_BY_CLASS = {
    "small": [("LEO", 55), ("SSO", 45)],
    "medium": [("LEO", 40), ("SSO", 18), ("GTO", 18), ("ISS", 12), ("MEO", 8), ("HEO", 4)],
    "heavy": [("LEO", 30), ("GTO", 30), ("TLI", 12), ("HEO", 10), ("MEO", 10), ("SSO", 8)],
}

# ---------------------------------------------------------------------------
# Customers (all fictional): (name, mission code, relative weight)
# ---------------------------------------------------------------------------
CUSTOMERS = [
    ("Aurora Orbital Networks", "AUR", 16),
    ("Skyloom Communications", "SKY", 13),
    ("Northstar Geo Services", "NGS", 10),
    ("Helio Dynamics", "HEL", 9),
    ("Cobalt Ridge Defense Systems", "CRD", 8),
    ("Tidewater Remote Sensing", "TRS", 7),
    ("Vantage Point Imaging", "VPI", 6),
    ("Blue Meridian Telecom", "BMT", 6),
    ("Polar Arc Analytics", "PAA", 5),
    ("Concordia Research Consortium", "CRC", 4),
    ("Stellar Freight Cooperative", "SFC", 4),
    ("Ionwave Propulsion Labs", "IWL", 3),
    ("Argent Microgravity Works", "AMW", 3),
    ("Cascade Weather Systems", "CWS", 3),
    ("Redline Orbital Logistics", "ROL", 2),
    ("Meridian Demo Payloads", "MDP", 1),
]

# ---------------------------------------------------------------------------
# Scrub reasons by category
# ---------------------------------------------------------------------------
SCRUB_REASONS = {
    "weather": [
        "Upper-level winds out of limits",
        "Cumulus cloud rule violation",
        "Lightning within 10 nm of the pad",
        "Ground winds exceed vehicle limits",
        "Thick cloud layer rule violation",
        "Anvil cloud rule violation",
    ],
    "technical": [
        "Engine sensor out-of-family reading",
        "Ground-side LOX valve fault",
        "Stage 2 helium leak",
        "Flight computer voting disagreement",
        "Hydraulic pressure drop on TVC system",
        "Umbilical retract mechanism failure",
    ],
    "range": [
        "Boat in downrange hazard area",
        "Aircraft in restricted airspace",
        "Range tracking radar outage",
    ],
    "payload": [
        "Payload environmental alarm",
        "Customer requested hold",
    ],
}
SCRUB_CATEGORY_WEIGHTS = [("weather", 45), ("technical", 40), ("range", 10), ("payload", 5)]
SCRUB_HOLD_POINTS_S = [3600, 2700, 1800, 900, 600, 300, 120, 60, 45, 30, 10]

# ---------------------------------------------------------------------------
# Suppliers (all fictional) and parts
# ---------------------------------------------------------------------------
SUPPLIER_NAMES = [
    "Cascadia Precision Castings", "Ridgeline Avionics", "Ironpeak Composites",
    "Summit Valve & Fitting", "Aster Guidance Systems", "Harborline Cryogenics",
    "Vermillion Seals & Gaskets", "Quartzline Optics", "Trailhead Machining",
    "Northbay Fasteners", "Kestrel Turbomachinery", "Palisade Electronics",
    "Drift Creek Software", "Ember Alloy Foundry", "Glacier Instrumentation",
    "Copperfield Harnesses", "Longitude Antenna Works", "Silverthread Textiles",
    "Bluegrass Bearings", "Foxtail Pyrotechnics", "Granite Coast Actuators",
    "Windward Tank & Vessel", "Halcyon Test Labs", "Meridian Ground Systems",
]
SUPPLIER_COUNTRIES = ["USA", "USA", "USA", "Germany", "Japan", "Canada", "UK", "France", "South Korea", "Italy"]
SUPPLIER_CERTS = ["AS9100D", "AS9100D", "AS9100D", "ISO 9001", "NADCAP + AS9100D"]

PART_CATALOG = {
    "Propulsion": ("PRO", [
        "Turbopump Assembly", "Main Injector", "Combustion Chamber Liner",
        "Gas Generator", "LOX Main Valve", "Fuel Main Valve",
        "Igniter Cartridge", "Nozzle Extension",
    ]),
    "Structures": ("STR", [
        "Interstage Adapter", "Payload Adapter Ring", "Thrust Structure",
        "Common Dome", "Fairing Half", "Grid Fin", "Landing Leg Strut",
    ]),
    "Avionics": ("AVN", [
        "Flight Computer", "Power Distribution Unit", "Telemetry Transmitter",
        "GPS Receiver", "Battery Module", "Engine Controller",
    ]),
    "GNC": ("GNC", [
        "Inertial Measurement Unit", "TVC Actuator", "Cold Gas Thruster Pod",
        "Star Tracker", "Rate Gyro Package",
    ]),
    "Pressurization": ("PRS", [
        "COPV Helium Tank", "Pressure Regulator", "Relief Valve", "Pneumatic Manifold",
    ]),
    "Recovery": ("RCV", [
        "Drogue Parachute", "Deployable Aero Surface", "Recovery Beacon",
    ]),
    "Ground Support": ("GSE", [
        "Umbilical Quick Disconnect", "Hold-Down Clamp", "Cryo Transfer Hose",
        "Strongback Hydraulic Cylinder",
    ]),
}
PART_COST_BASE = {
    "Propulsion": 90000, "Structures": 40000, "Avionics": 25000, "GNC": 30000,
    "Pressurization": 15000, "Recovery": 8000, "Ground Support": 12000,
}
MATERIALS = [
    "Inconel 718", "Ti-6Al-4V", "Al-Li 2195", "Stainless 304L",
    "Carbon Fiber Composite", "Copper C18150", "PTFE", "Silica Phenolic",
]

# ---------------------------------------------------------------------------
# People (all fictional)
# ---------------------------------------------------------------------------
TECHNICIANS = [
    "Dana Whitfield", "Marcus Bell", "Priya Raman", "Elena Vasquez",
    "Tomas Lindgren", "Aisha Okafor", "Grace Liu", "Robert Calloway",
    "Miguel Serrano", "Hannah Brandt", "Kofi Mensah", "Yuki Tanabe",
    "Sofia Marchetti", "Owen Gallagher",
]
ASSIGNEES = [
    "Dana Whitfield", "Priya Raman", "Elena Vasquez", "Grace Liu",
    "Robert Calloway", "Aisha Okafor", "Tomas Lindgren", "Hannah Brandt",
]

WO_DISPOSITIONS = [("repair", 35), ("replace", 30), ("use-as-is", 20), ("scrap", 15)]
WO_PRIORITIES = [("P1", 10), ("P2", 30), ("P3", 40), ("P4", 20)]

# ---------------------------------------------------------------------------
# Cost centers: (name, base daily USD)
# ---------------------------------------------------------------------------
COST_CENTERS = [
    ("Propulsion", 8200.0),
    ("Avionics", 5400.0),
    ("Range Operations", 3900.0),
    ("Facilities", 2600.0),
    ("Cloud & IT", 1800.0),
]

# ---------------------------------------------------------------------------
# Security findings
# ---------------------------------------------------------------------------
FINDING_SOURCES = [("CodeQL", 25), ("Dependabot", 30), ("Trivy", 20), ("ZAP", 15), ("Defender for Cloud", 10)]
FINDING_SEVERITIES = [("critical", 8), ("high", 27), ("medium", 40), ("low", 25)]
FINDING_SLA_DAYS = {"critical": 7, "high": 30, "medium": 60, "low": 90}
FINDING_COMPONENTS = [
    "apps/launch-ops/api", "apps/launch-ops/web", "apps/control-tower/web",
    "apps/copilot-svc", "apps/shared/spec-renderer", "infra/bicep",
    "infra/entra", ".github/workflows", "data/generators", "apps/vuln-lab",
]
FINDING_TITLES = [
    "SQL string concatenation in query builder",
    "Outdated base image with known CVEs",
    "Missing HTTP security headers",
    "Dependency with known prototype pollution",
    "Hardcoded connection string in test fixture",
    "Container runs as root",
    "Reflected XSS in search parameter",
    "Insecure deserialization of cached payload",
    "Overly permissive CORS policy",
    "Unpinned GitHub Action version",
    "Secrets echoed to build log output",
    "Path traversal in file download endpoint",
    "TLS certificate validation disabled in dev client",
    "Regular expression denial of service",
    "Server-side request forgery in webhook fetcher",
    "Weak JWT signing configuration",
]
