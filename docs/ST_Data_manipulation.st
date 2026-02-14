FUNCTION_BLOCK ST_Data_manipulation
VAR CONSTANT
    MinArvo : DINT := 5000;       // Anturin arvo pohjalla
    MaxArvo : DINT := 9630000;    // Anturin arvo täydessä säiliössä
    TilavuusMax : REAL := 3390.0; // Säiliön tilavuus ml
    KorkeusMax : REAL := 220.0;   // Säiliön korkeus mm
END_VAR
VAR_INPUT
END_VAR
VAR_OUTPUT
END_VAR
VAR
    Snapshot : REAL;              // Tallennettu tilavuus
    RajoitettuArvo : DINT;        // Anturin arvo rajattuna min-max välille
END_VAR

// Säiliö tyhjenee sammuttaa automaatin *ota pois jossei toimi*
VAR
    // --- Parametrit (säädettävissä) ---
    EmptyThreshold_ml : REAL := 10.0;       // "Tyhjä" jos Tilavuus_ml <= 10 ml
    NotEmptyThreshold_ml : REAL := 20.0;    // "Ei-tyhjä" jos Tilavuus_ml >= 20 ml (hystereesi)
    WaterPresenceThreshold_ml : REAL := 50.0; // "Vettä on ollut" jos joskus >= 50 ml

    // --- Sisäiset tilat ---
    had_water_since_start : BOOL := FALSE;  // latchettu tieto: onko vettä ollut ajon aikana
    empty_state : BOOL := FALSE;            // hysteresis-pohjainen tyhjyyden tila

    // --- Ajastimet ---
    tEmpty5s : TON;                         // 5 s varmistus kun empty_state = TRUE
    // (Ei monofloppia, koska teemme syklipulssin R_TRIG:llä vakiona)

    // --- Pulssin generointi ---
    rTrig_EmptyOk : R_TRIG;                 // Reunanhavaitseminen (nouseva reuna)

    // --- Välisignaalit ---
    allow_stop : BOOL;                      // pysäytys sallittu (ei pulloja linjalla)
    timer_in : BOOL;                        // TON:lle syöttö
END_VAR
// *** Resetointi napilla S3 ***
IF S3 THEN
    HMI_valve_timer := T#0MS;
    HMI_fill := 0;
    Snapshot := 0;
END_IF;

// *** Rajaukset automaattiajon käynnistyspulssilla S8 ***
IF S8 THEN
    // Rajataan HMI_fill välille 500–3000 ml
    IF HMI_fill <= 500 THEN
        HMI_fill := 500;
    ELSIF HMI_fill > 3000 THEN
        HMI_fill := 3000;
    END_IF;

    // Rajataan HMI_valve_timer välille 0–2000 ms
    IF HMI_valve_timer < T#0MS THEN
        HMI_valve_timer := T#0MS;
    ELSIF HMI_valve_timer > T#2000MS THEN
        HMI_valve_timer := T#2000MS;
    END_IF;
END_IF;

// *** Snapshot otetaan S8 painikkeen painalluksesta ***
IF S8 THEN
    Snapshot := Tilavuus_ml + HMI_fill;
END_IF;

// *** Täytön aloitus ***
IF (HMI_fill >= 500) AND Automaattitila_paalle THEN
    Fill_start := TRUE;
ELSE
    Fill_start := FALSE;
END_IF;

// *** Vertailu nykyiseen tilavuuteen ***
IF Tilavuus_ml >= Snapshot THEN
    Fill_ready := TRUE;
ELSE
    Fill_ready := FALSE;
END_IF;

// *** Rajaus anturin arvolle ***
IF _4PV1 < MinArvo THEN
    RajoitettuArvo := MinArvo;
ELSIF _4PV1 > MaxArvo THEN
    RajoitettuArvo := MaxArvo;
ELSE
    RajoitettuArvo := _4PV1;
END_IF;

// *** Skaalaus tilavuudeksi ja korkeudeksi ***
Tilavuus_ml := ((TO_REAL(RajoitettuArvo) - TO_REAL(MinArvo)) * TilavuusMax) / (TO_REAL(MaxArvo) - TO_REAL(MinArvo));
Korkeus_mm := ((TO_REAL(RajoitettuArvo) - TO_REAL(MinArvo)) * KorkeusMax) / (TO_REAL(MaxArvo) - TO_REAL(MinArvo));

// VE1 TANK empty HMI alarm anturin kääntö
IF _4B3=1
	THEN
	HMI_4B3_alarm:=0;
	ELSE
		HMI_4B3_alarm:=1;
END_IF


// --- Päivitetään "säiliössä on ollut vettä" -latch ---
// Kun Tilavuus_ml ylittää veden läsnäolon kynnyksen edes kerran, muistetaan se.
IF Tilavuus_ml >= WaterPresenceThreshold_ml THEN
    had_water_since_start := TRUE;
END_IF;

// --- Resetointi S3:lla palauttaa ajotilanteen ---
// Ei käytetä latcheja hälyn pitämiseen, mutta tämä nollaa muistia "veden ollut" -seurannasta tarvittaessa.
IF S3 THEN
    had_water_since_start := FALSE;
    empty_state := FALSE; // aloita neutraalista tilasta
END_IF;

// ---- AUTOMAATIN SAMMUTUS VEDEN LOPPUESSA	
	// --- Hysteresis: empty_state muodostus ---
	// Anturin heittelyn takia käytetään ala- ja ylärajaa.
	// - Jos tällä hetkellä tyhjä, pysytään tyhjänä kunnes ylitetään NotEmptyThreshold_ml.
	// - Jos ei tyhjä, siirrytään tyhjäksi kun alitetaan EmptyThreshold_ml.
	IF empty_state THEN
		// Tyhjä-tilassa poistutaan vain jos ollaan selvästi ei-tyhjiä
		IF Tilavuus_ml >= NotEmptyThreshold_ml THEN
			empty_state := FALSE;
		END_IF;
	ELSE
		// Ei-tyhjä-tilassa mennään tyhjäksi vasta kun alitetaan tyhjän kynnys
		IF Tilavuus_ml <= EmptyThreshold_ml THEN
			empty_state := TRUE;
		END_IF;
	END_IF;
	
	// --- Stopin esto jos pullot kuljettimella (inhibit) ---
	allow_stop := NOT bottles_on_conveyor;
	
	// --- 5 s varmistusajastin ---
	// Ajastin käy vain, jos: (1) ollaan tyhjänä hysteresis-logiikan mukaan,
	// (2) säiliössä on ollut vettä vähintään kerran ajon aikana,
	// (3) stoppi on sallittu (ei pulloja kuljettimella).
	timer_in := empty_state AND had_water_since_start AND allow_stop;
	tEmpty5s(IN := timer_in, PT := T#5S);
	
	// --- Pulssin generointi, kun 5 s ehto täyttyy ---
	// Käytetään R_TRIG:ä tEmpty5s.Q:n nousevaan reunaan → yksi PLC-sykli pulssi.
	rTrig_EmptyOk(CLK := tEmpty5s.Q);
	
	// --- Ulostulot (pulssi) ---
	// Tuota yksi-syklinen pulssi pysäytykseen ja pudota automaattitila pois samassa syklissä.
	IF rTrig_EmptyOk.Q THEN
		Empty_tank_stop := TRUE;         // pulssi
		Automaattitila_paalle := FALSE;  // pakota automaatti pois
	ELSE
		Empty_tank_stop := FALSE;
	END_IF;
