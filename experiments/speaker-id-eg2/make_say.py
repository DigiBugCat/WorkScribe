import sys, subprocess, json, soundfile as sf
S = sys.argv[1]
voices = ["Albert","Daniel","Fred","Karen","Moira","Ralph","Samantha","Aman"]
texts = ["The quarterly budget review is scheduled for Thursday afternoon in the main conference room.",
 "Please remember to send the updated slides to the marketing team before the end of the week.",
 "We should probably migrate the database before we change anything else in the deployment pipeline.",
 "The weather has been unusually warm this autumn, and the leaves are only now starting to fall.",
 "I think the customer would be happier if we called them directly instead of sending another email.",
 "Our new hire starts on Monday, so let's make sure her laptop and accounts are ready by then.",
 "The recipe calls for two cups of flour, a pinch of salt, and three eggs beaten until fluffy.",
 "If the train is delayed again tomorrow, I will work from home and join the meeting by video.",
 "Can you check whether the invoice from the vendor was paid, and if not, escalate it to finance?",
 "The museum's new exhibit features paintings from the late nineteenth century and early photographs."]
out = []
for v in voices:
    for i, t in enumerate(texts):
        p = f"{S}/data/say/{v}_{i}.wav"
        subprocess.run(["say","-v",v,"-o",p,"--file-format=WAVE","--data-format=LEI16@16000",t], check=True)
        d = sf.info(p).duration
        out.append({"path":p,"spk":v,"text":i,"start":0,"dur":min(d,10.0)})
json.dump(out, open(f"{S}/data/say_manifest.json","w"))
print(len(out), min(c["dur"] for c in out), max(c["dur"] for c in out))
