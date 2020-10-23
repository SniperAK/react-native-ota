import { NativeModules } from 'react-native';

type OtaType = {
  multiply(a: number, b: number): Promise<number>;
};

const { Ota } = NativeModules;

export default Ota as OtaType;
