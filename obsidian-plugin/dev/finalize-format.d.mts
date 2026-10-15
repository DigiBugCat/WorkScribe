export function finalizeFormat(meeting: {
 document:{source:string;blocks:{id:string;text:string;to:number;owned?:unknown}[]};
 notes:{id:string;enhanced?:{text:string}}[];brief?:string;
 missedTopics:{topic:string;text:string}[];
 actionItems:{text:string;owner?:string;due?:string}[];
}): {text:string;insertions:{at:number;text:string}[]};
