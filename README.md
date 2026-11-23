# FS25_ServerRules – Server Rules: Balance and Roles (Farming Simulator 25)

Admin tool for **dedicated multiplayer servers**. The server reads all values from a settings file
and sends them to every player on join. Players cannot change them, and you can change values
without releasing a new mod version.

> Status: **work in progress** – stages 1 and 2 tested on a dedicated server, not yet with
> clients. Use at your own risk; back up your savegame.

## Stages

| Stage | Content | Status |
|---|---|---|
| 1 | Shop prices and daily upkeep of all store items (vehicles, tools, buildings, hand tools) | server-tested |
| 2 | Productions: recipes, cycles per hour, operating costs, storage; selling prices of goods | server-tested |
| 3 | Roles per farm: allowed purchases, contracts, loans, selling points; role menu in game | planned |

## Installation

**Players (one line):** open PowerShell and paste

```powershell
irm https://raw.githubusercontent.com/VitaCuraHUB/FS25_ServerRules/main/install.ps1 | iex
```

It downloads the newest release, checks its SHA-256 and copies it into your mods folder (also if
you use a mods folder override). Nothing else is changed.

**Manually:**

- Put `FS25_ServerRules.zip` into the mods folder of the **server and every player** (same file for
  all – multiplayer requires identical mods).
- Activate it for the savegame (dedicated server: web interface).
- On first start the server creates `modSettings/FS25_ServerRules/serverRules.xml` in its profile
  folder (e.g. `Documents/My Games/FarmingSimulator2025/`). Edit it there.

## Settings file

```xml
<serverRules version="1">
    <!-- reloadInterval: seconds between checks for changes (0 = only at server start)
         writeCheckFile: write serverRules-check.xml with the values really in effect -->
    <general reloadInterval="60" writeCheckFile="false"/>
    <prices>
        <!-- no criteria = every item -->
        <rule priceFactor="1.0"/>
        <!-- all buildings with productions from mods: 5x price -->
        <rule source="mod" category="productionPoints" priceFactor="5" upkeepFactor="3"/>
        <!-- one whole mod -->
        <rule mod="FS25_SomeFactoryPack" priceFactor="10"/>
        <!-- one brand of vehicles -->
        <rule brand="FENDT" species="vehicle" upkeepFactor="1.5"/>
        <!-- one item: mod name + path inside the zip, or data/... for base game items -->
        <rule item="FS25_SomeFactoryPack/xml/bakery.xml" price="250000" dailyUpkeep="120"/>
        <rule item="data/placeables/brandless/productionPointsGeneric/bakery/bakery.xml" price="175000"/>
    </prices>
</serverRules>
```

**Criteria** (every given criterion must match): `item`, `mod`, `category` (shop category name,
e.g. `tractorsL`, `productionPoints`), `brand` (e.g. `FENDT`), `species` (`vehicle`, `placeable`,
`handTool`), `source` (`mod`, `base`, `dlc`). Case does not matter.

**Values:** `price` or `priceFactor`; `dailyUpkeep` or `upkeepFactor`. Shop name: `name` (replaces it) or
`nameSuffix` (appended, e.g. `nameSuffix=" (large)"`). Configuration surcharges
(engine, tyres …) scale with the price factor.

**Which rule wins:** the most specific matching rule (item > mod > category/brand > species >
source > no criteria); on a tie the later one in the file. Price and upkeep are decided
separately, so one rule can set the price and another one the upkeep.

**Already bought items** keep their purchase value (it is stored in the savegame). Daily upkeep
changes apply to them too.

### Productions (stage 2)

```xml
<productions>
    <!-- one recipe of one building: absolute values; input/output amounts per fill type -->
    <production item="FS25_SomeMap/maps/placeables/bakery/bakery.xml" id="cake" cyclesPerHour="0.5" costsPerHour="10">
        <output fillType="CAKE" amount="25"/>
    </production>
    <!-- every recipe of a mod (incl. map productions of a map mod): factors -->
    <production mod="FS25_SomeFactoryPack" cyclesFactor="0.1" costsFactor="5" inputFactor="1" outputFactor="0.5"/>
    <!-- storage: one fill type, or all (without fillType = also the total capacity) -->
    <storage item="FS25_SomeMap/maps/placeables/bakery/bakery.xml" fillType="CAKE" capacity="3000"/>
    <storage mod="FS25_SomeFactoryPack" capacityFactor="2"/>
</productions>
<fillTypes>
    <!-- selling price factor at all selling points -->
    <fillType name="CAKE" priceFactor="0.8"/>
    <!-- always "sell directly" (e.g. a substitute currency): the building pays euro, the output mode cannot be changed -->
    <fillType name="SOMECOIN" forceDirectSell="true"/>
</fillTypes>
```

Works for bought buildings, map productions and greenhouses. Only **one** rule applies per recipe
(the most specific: item > mod, with `id` > without); it is not merged with less specific rules.
Rules are applied while the building loads, before the savegame fill levels – a larger storage
keeps its contents across restarts. Production runs on the server; clients get the rules for the
display. Selling price factors are applied by the server (the price clients see comes from the
server – to be confirmed in a client test).

### Generated rules

The server also reads `serverRules-auto.xml` from the same folder (e.g. written by a balancing
tool). Rules in `serverRules.xml` always win over generated ones where both match.

## How it works

- Server: reads the file at start and then every `reloadInterval` seconds; if the result changed,
  it applies the new values and sends them to all players.
- Clients: get a snapshot on join (in chunks) and ask again every 10 s until it is complete.
- Purchases are always calculated by the server, so a client cannot buy at a different price.

## Building

`powershell -ExecutionPolicy Bypass -File tools\build.ps1` → `dist\FS25_ServerRules.zip` (+ SHA-256).

## License

MIT – see `LICENSE`. No code from other mods is included.
