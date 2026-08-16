R4JS.R4P
========

R4JS ist die wiederverwendbare, begrenzte JavaScript-Laufzeit von R4OS.
Das Modul registriert die Rolle application.javascript und bleibt
ausserhalb von Kernel, R4DRAW und einzelnen Anwendungen.

Enthalten sind Lexer, Parser, Bytecodecompiler und eine validierte Stack-VM
fuer den in Klickifax benoetigten ECMAScript-Grundbestand: lexikalische
Bindungen, Funktionen, Closures, Kontrollfluss, Ausnahmen, Objekte, Arrays,
synchrone und asynchrone Generatoren, Async-Funktionen, await, for-await-of,
Module und zentrale Standardtypen. Der produktive Pfad fuehrt keine AST-
Knoten aus. Ein JIT ist bewusst nicht Bestandteil dieser Stufe.

Die Laufzeit besitzt feste Obergrenzen, einen Mark-and-Sweep-Collector,
einen an Bytecodeinstruktionen gebundenen Schrittzaehler mit Abbruch,
explizite VM-Frames, eine deterministische Task- und Microtask-Warteschlange
sowie Promises. VM-Stack und Frames sind GC-Wurzeln. Der Parser-Tokenpuffer
wird nach erfolgreichem Parsen fuer Instruktionen und Segmentmetadaten
wiederverwendet. Alle Speicherbereiche gehoeren einer Runtime-Instanz und
werden weder im Kernel noch in R4DRAW abgelegt.

Parser, Compiler, VM und Hostfunktionen schreiben Fehlerart, Quellname,
Zeile, Spalte, Quellkontext und den aktiven Bytecode-Aufrufstack in einen
gemeinsamen Diagnosezustand. In JavaScript gefangene Laufzeitfehler besitzen
zusaetzlich die nicht aufzaehlbaren Felder `stack`, `sourceName`,
`lineNumber` und `columnNumber`.

Das dauerhaft geladene R4P-Modul enthaelt keine maximalen Runtime- oder
Program-Arbeitsbereiche im BSS. Dispatchoperationen fordern sie ueber R4DEV
bedarfsgesteuert an; auch Modul-, Eval- und WebRuntime-Programme werden ueber
den gemeinsamen ProgramAllocator angelegt und nach der Operation freigegeben.
Generatoren fordern darueber ihren VM-Zustand beim Erzeugen und einen eigenen
1-MB-Ausfuehrungsstack erst beim ersten `next` an. Async-Funktionen starten
auf einem gleich grossen, bedarfsgesteuerten Fiber und setzen ihn nach await
ausschliesslich als Promise-Microtask fort. Die Stacks werden beim Abschluss
sofort freigegeben. Es gibt keinen festen Fiberpool; unerreichbare Generatoren
und Async-Funktionen geben Zustand und Stack ueber denselben GC-Lebenszyklus
wieder frei.

Operationen:

- 1: Capabilities
- 2: Parse summary
- 3: Evaluate summary
- 4: Selftest
- 5: Web-runtime selftest

Die generische R4P-Dispatch-ABI ist die einzige Modulgrenze. Die
anwendungsseitige `r4os.web_runtime` bindet Window, DOM, Ereignisse, Timer,
Fetch/XHR, Storage und Origin-Regeln an den Sprachkern. Operation 5 prueft
diese Verbindung im Gast; R4JS besitzt dabei weiterhin keinen privaten
Netzwerkpfad.
