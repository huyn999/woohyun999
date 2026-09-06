import java.util.Objects;

public class Car extends Vehicle {
    private int seats;

    public Car(String brand, String model, int year, int seats) throws InvalidVehicleDetailException {
        super(brand, model, year);
        if (seats <= 0)
        {
            throw new InvalidVehicleDetailException("the seats has to be more than 0.");
        }
        else
        {
            this.seats = seats;
        }
    }

    public int getSeats() {
        return seats;
    }

    public void setSeats(int seats) throws InvalidVehicleDetailException {
        if (seats <= 0) {
            throw new InvalidVehicleDetailException("the seats has to be more than 0.");
        }
        else{
            this.seats = seats;
        }

    }

    @Override
    public String toString() {
        return "Car [Brand: " + getBrand() + ", Model: " + getModel() + ", Year: " + getYear() + ", Seats: " + seats + "]";
    }

    @Override
    public boolean equals(Object obj) { // 같은 모델명, 생산년도, 브랜드, 같은 좌석 수이면 같은 객체로 판단하기 위해 설정
        if (!super.equals(obj)) return false;
        Car car = (Car) obj;
        if(seats == car.seats)
        {
            return true;
        }
        else{
            return false;
        }
    }

    @Override
    public int hashCode() {
        return Objects.hash(super.hashCode(), seats); // 브랜드, 모델명, 생산년도, 좌석수를 조합해 해시값 생성
    }
}
