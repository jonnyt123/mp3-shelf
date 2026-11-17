export type PlayerGesture="close"|"next"|"previous"|null;
export function playerGesture(dx:number,dy:number,threshold=70):PlayerGesture{const horizontal=Math.abs(dx),vertical=Math.abs(dy);if(dy>threshold&&vertical>horizontal*1.2)return"close";if(horizontal>threshold&&horizontal>vertical*1.2)return dx<0?"next":"previous";return null}
