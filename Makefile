SPC=spcomp.exe

all: NadeBoost.sp copyToGame

NadeBoost.sp:
	$(SPC) src/NadeBoost.sp -\;+ -E
	mkdir -p out
	mv src/NadeBoost.smx out/NadeBoost.smx

copyToGame:
	cp out/NadeBoost.smx "/mnt/c/Users/David/Desktop/csgoserver/csgo/addons/sourcemod/plugins/NadeBoost.smx"

clean:
	rm -r out