const int N = 6;
int drivePins[N] = {2,3,4,5,6,7};
int sensePins[N] = {8,9,10,11,12,13};

int matrix[N][N];
int mapIN[N];
int lastMapIN[N];

void setup() {
  Serial.begin(115200);
  for (int i=0;i<N;i++){
    pinMode(drivePins[i], OUTPUT);
    digitalWrite(drivePins[i], HIGH);
  }
  for (int j=0;j<N;j++){
    pinMode(sensePins[j], INPUT_PULLUP);
  }
  for (int i=0;i<N;i++){
    mapIN[i] = -1;
    lastMapIN[i] = -2;
  }
}

void clearMatrix(){
  for(int i=0;i<N;i++) for(int j=0;j<N;j++) matrix[i][j]=0;
}

void scanMatrix(){
  clearMatrix();
  for(int i=0;i<N;i++){
    digitalWrite(drivePins[i], LOW);
    delayMicroseconds(800);
    for(int j=0;j<N;j++){
      if(digitalRead(sensePins[j]) == LOW) matrix[i][j] = 1;
    }
    digitalWrite(drivePins[i], HIGH);
    delayMicroseconds(200);
  }
}

void computeMapIN(){
  for(int s=0;s<N;s++){
    int found = -1;
    for(int d=0;d<N;d++){
      if(matrix[d][s]==1){ found = d; break; }
    }
    mapIN[s] = found;
  }
}

int computeLoad(){
  int load = 0;
  for(int i=0;i<N;i++) if(mapIN[i] >= 0) load++;
  return load;
}

// Deterministic hash from current state only.
// Same cables plugged in = same topo value, always.
int computeTopo(){
  int hash = 0;
  for(int i=0;i<N;i++){
    if(mapIN[i] >= 0){
      hash += (i + 1) * 7 + (mapIN[i] + 1) * 13;
    }
  }
  return hash;
}

void loop() {
  scanMatrix();
  computeMapIN();

  bool changed = false;
  for(int i=0;i<N;i++){
    if(mapIN[i] != lastMapIN[i]){
      changed = true;
      if(mapIN[i] >= 0){
        Serial.print("PATCH IN"); Serial.print(i+1);
        Serial.print(" OUT"); Serial.println(mapIN[i]+1);
      } else {
        Serial.print("UNPATCH IN"); Serial.println(i+1);
      }
      lastMapIN[i] = mapIN[i];
    }
  }

  if(changed){
    int load = computeLoad();
    int topo = computeTopo();
    Serial.print("CONN:"); Serial.print(load);
    Serial.print(" TOPO:"); Serial.println(topo);
  }

  delay(30);
}