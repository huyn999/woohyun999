import java.util.Objects;

public class Motorcycle extends Vehicle {
    private boolean hasSidecar;

    public Motorcycle(String brand, String model, int year, boolean hasSidecar) throws InvalidVehicleDetailException {
        super(brand, model, year);
        this.hasSidecar = hasSidecar;
    }

    public boolean isHasSidecar() {
        return hasSidecar;
    }

    public void setHasSidecar(boolean hasSidecar) {
        this.hasSidecar = hasSidecar;
    }

    @Override
    public String toString() {
        return "Motorcycle [ Brand: " + getBrand() + ", Model: " + getModel() + ", Year: " + getYear() +
                ", Has Sidecar: " + hasSidecar + "]";
    }

    @Override
    public boolean equals(Object obj) { // 같은 모델명, 생산년도, 브랜드, sidecar 유무가 같으면 같은 객체로 판단하기 위해 설정
        if (!super.equals(obj)) return false;
        Motorcycle motorcycle = (Motorcycle) obj;
        if(hasSidecar == motorcycle.hasSidecar)
        {
            return true;
        }
        else{
            return false;
        }
    }

    @Override
    public int hashCode() {
        return Objects.hash(super.hashCode(), hasSidecar); // 브랜드, 모델명, 생산년도조,sidecar 유무 조합해 해시값 생성
    }
}
