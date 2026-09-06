import java.util.Objects;

// Vehicle 클래스
public class Vehicle {
    private final String brand;
    private final String model;
    private int year;

    public Vehicle(String brand, String model, int year) throws InvalidVehicleDetailException {
        if (year < 1886) {
            throw new InvalidVehicleDetailException("the year has to be 1886 or later.");
        }
        this.brand = brand;
        this.model = model;
        this.year = year;
    }

    public String getBrand() {
        return brand;
    }

    public String getModel() {
        return model;
    }

    public int getYear() {
        return year;
    }

    public void setYear(int year) throws InvalidVehicleDetailException {
        if (year < 1886) {
            throw new InvalidVehicleDetailException("the year has to be 1886 or later.");
        }
        this.year = year;
    }

    @Override
    public String toString() {
        return "Vehicle [ Brand: " + brand + ", Model: " + model + ", Year: " + year + " ]";
    }

    @Override
    public boolean equals(Object obj)// 같은 모델명, 생산년도, 브랜드 이면 같은 객체로 판단하기 위해 설정
    {
        if (this == obj) return true;
        if (!(obj instanceof Vehicle vehicle)) {
            return false; // 객체의 타입이 Vehicle을 상속한 타입이 맞는지 확인,패턴매칭
        }
        return Objects.equals(model, vehicle.model)&& Objects.equals(brand, vehicle.brand) && year == vehicle.year;

    }

    @Override
    public int hashCode() {
        return Objects.hash(brand, model, year); // 브랜드, 모델명, 생산년도를 조합해 해시값 생성
    }
}
